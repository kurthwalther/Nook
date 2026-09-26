// Licensed under GPL-3.0. See LICENSE.
//
// Prueba del replay exacto de workflows sin abrir Nook. Correr con kurth/checks/replay.sh.
//  1. Utilidades del modelo (KurthWorkflowsReplayModelo.swift): parámetros, misma página, teclas.
//  2. Graba de verdad: KurthGrabadora.js en un WKWebView sin ventana sobre replay/original.html (y
//     su detalle.html), con eventos simulados; las navegaciones las suma este arnés como lo hace Nook.
//  3. Repite ese workflow con el bucle real (KurthReplayEjecutor) y el localizador real
//     (KurthCopilot.js + KurthReplay.js en el mundo "KurthCopilot"): primero contra la misma página,
//     después contra replay/cambiado.html servida en la MISMA dirección (texto de botón distinto,
//     clases e ids distintos, orden movido, enlace vuelto botón). Tiene que completar la cambiada.
//  4. Un paso que ya no existe (sin nada parecido) pasa al respaldo y la corrida falla en ese paso;
//     un paso con «secreto» detiene la corrida con "necesita que inicies sesión".
// Cada comprobación imprime ✅ o ❌; termina con 1 si alguna falló. Con TRAZA=1 imprime además cada
// paso, cada búsqueda y cada acción (para ver dónde se atora algo).
//
// No prueba lo que necesita Nook: pestañas reales, clics nativos, la guardia de irreversibles, el
// agente del panel como respaldo, el modo sin restricciones ni el registro en disco.

import AppKit
import WebKit

@main
struct ReplayCheck {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0) // que se vea hasta dónde llegó aunque se cuelgue
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let repo = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
            let prueba = PruebaReplay(repo: repo)
            prueba.utilidades()
            await prueba.todo()
            print(prueba.fallas == 0 ? "\nTodo bien." : "\n\(prueba.fallas) falla(s).")
            exit(prueba.fallas == 0 ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { print("❌ se acabó el tiempo"); exit(1) }
        app.run()
    }
}

@MainActor
final class PruebaReplay: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply, WKScriptMessageHandler, KurthReplayPagina {
    let repo: URL
    var fallas = 0
    var webView: WKWebView!
    let sitio: URL
    let mundoGrabadora = WKContentWorld.world(name: "KurthGrabadora")
    let mundoCopiloto = WKContentWorld.world(name: "KurthCopilot")
    var copiloto = ""
    var localizador = ""

    // Grabación
    var grabando = false
    var inicio = Date()
    var pasos: [KurthWorkflowPaso] = []

    init(repo: URL) {
        self.repo = repo
        sitio = FileManager.default.temporaryDirectory.appendingPathComponent("kurth-replay-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    func ok(_ nombre: String, _ condicion: Bool, _ detalle: @autoclosure () -> String = "") {
        if condicion { print("✅ \(nombre)") } else { fallas += 1; print("❌ \(nombre)\n   \(detalle())") }
    }

    // MARK: - 1. Utilidades

    func utilidades() {
        print("── Utilidades")
        typealias R = KurthReplayModelo
        let params = [KurthWorkflowParametro(nombre: "producto", descripcion: "", ejemplo: "bolsa negra"),
                      KurthWorkflowParametro(nombre: "n", descripcion: "", ejemplo: "1")]
        let v = ["producto": "cartera", "n": "7"]
        ok("parámetro: el valor completo", R.sustituir("bolsa negra", parametros: params, valores: v) == "cartera")
        ok("parámetro: dentro de un texto", R.sustituir("Busca bolsa negra ya", parametros: params, valores: v) == "Busca cartera ya")
        ok("parámetro: en una dirección, codificado", R.sustituir("https://x.mx/s?q=bolsa%20negra&p=1", parametros: params, valores: v, enDireccion: true) == "https://x.mx/s?q=cartera&p=1",
           R.sustituir("https://x.mx/s?q=bolsa%20negra&p=1", parametros: params, valores: v, enDireccion: true))
        ok("parámetro corto no toca direcciones", R.sustituir("https://x.mx/1/a", parametros: params, valores: v, enDireccion: true) == "https://x.mx/1/a")
        let cruzados = [KurthWorkflowParametro(nombre: "a", descripcion: "", ejemplo: "rojo"), KurthWorkflowParametro(nombre: "b", descripcion: "", ejemplo: "azul")]
        ok("parámetros cruzados no se pisan", R.sustituir("rojo y azul", parametros: cruzados, valores: ["a": "azul", "b": "rojo"]) == "azul y rojo")
        ok("misma página ignora consulta y www", R.mismaPagina("https://www.krei.mx/ventas/?t=1", "https://krei.mx/ventas#x"))
        ok("otra ruta es otra página", !R.mismaPagina("https://krei.mx/ventas", "https://krei.mx/compras"))
        ok("tecla ⌘K", R.tecla("⌘K") == ("k", ["cmd"]))
        ok("tecla Esc", R.tecla("Esc") == ("Escape", []))
        ok("tecla ⇧Tab", R.tecla("⇧Tab") == ("Tab", ["shift"]))
    }

    // MARK: - Sitio de prueba

    /// La versión de la página que se sirve en la misma dirección de siempre (index.html, detalle.html).
    func servir(_ version: String, quitar: String? = nil) {
        try? FileManager.default.createDirectory(at: sitio, withIntermediateDirectories: true)
        let base = repo.appendingPathComponent("kurth/checks/replay")
        for (origen, destino) in [("\(version).html", "index.html"), ("\(version)-detalle.html", "detalle.html")] {
            var html = (try? String(contentsOf: base.appendingPathComponent(origen), encoding: .utf8)) ?? ""
            if let quitar { html = html.split(separator: "\n").filter { !$0.contains(quitar) }.joined(separator: "\n") }
            try? html.write(to: sitio.appendingPathComponent(destino), atomically: true, encoding: .utf8)
        }
    }

    var indice: URL { sitio.appendingPathComponent("index.html") }

    func cargar(_ url: URL) async {
        if url.isFileURL { webView.loadFileURL(url, allowingReadAccessTo: sitio) } else { webView.load(URLRequest(url: url)) }
        try? await Task.sleep(for: .milliseconds(80))
        let limite = Date().addingTimeInterval(10)
        while webView.isLoading, Date() < limite { try? await Task.sleep(for: .milliseconds(40)) }
        try? await Task.sleep(for: .milliseconds(60))
    }

    @discardableResult
    func js(_ codigo: String, _ args: [String: Any] = [:], mundo: WKContentWorld) async throws -> Any? {
        do { return try await webView.callAsyncJavaScript(codigo, arguments: args, in: nil, contentWorld: mundo) }
        catch {
            let ns = error as NSError
            throw KurthReplayError(ns.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
        }
    }

    func pagina(_ codigo: String) async { _ = try? await js(codigo, mundo: .page) }

    // MARK: - 2. Grabar

    /// Lo que la página anota (anotar(x) en las páginas de prueba): lo que de verdad pasó.
    var hechos: [String] = []
    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { if let x = message.body as? String { hechos.append(x) } }
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage,
                                           replyHandler: @escaping (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            let cuerpo = message.body as? [String: Any] ?? [:]
            if cuerpo["tipo"] as? String == "hola" { replyHandler(["grabando": grabando], nil); return }
            if grabando, let d = cuerpo["paso"] as? [String: Any] { recibir(d) }
            replyHandler(nil, nil)
        }
    }

    /// Lo mismo que KurthWorkflows.recibirPaso, sin pestañas de Nook.
    func recibir(_ d: [String: Any]) {
        guard let tipo = (d["tipo"] as? String).flatMap(KurthWorkflowPaso.Tipo.init(rawValue:)) else { return }
        let cuando = (d["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()
        var p = KurthWorkflowPaso(t: max(0, cuando.timeIntervalSince(inicio)), tipo: tipo)
        func texto(_ k: String) -> String? { (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        p.rol = texto("rol"); p.nombre = texto("nombre"); p.selector = texto("selector")
        p.valor = texto("valor") ?? (tipo == .escribir ? "" : nil)
        p.href = texto("href"); p.tecla = texto("tecla"); p.detalle = texto("detalle")
        p.secreto = (d["secreto"] as? Bool) == true ? true : nil
        p.doble = (d["doble"] as? Bool) == true ? true : nil
        p.pos = (d["pos"] as? [NSNumber])?.map(\.doubleValue)
        p.orden = (d["orden"] as? NSNumber)?.intValue
        p.url = webView.url?.absoluteString
        p.tab = "A"
        KurthWorkflowsModelo.agregar(p, a: &pasos)
    }

    /// Lo que Nook suma al ver cambiar la dirección de la pestaña.
    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard grabando, let url = webView.url?.absoluteString else { return }
            var p = KurthWorkflowPaso(t: Date().timeIntervalSince(inicio), tipo: .navegar)
            p.url = url; p.tab = "A"; p.titulo = webView.title
            KurthWorkflowsModelo.agregar(p, a: &pasos)
        }
    }

    func evento(_ selector: String, _ js: String) async {
        await pagina("const el = document.querySelector(\(String(reflecting: selector))); \(js)")
        try? await Task.sleep(for: .milliseconds(60))
    }

    func clic(_ selector: String) async {
        await evento(selector, "el.dispatchEvent(new MouseEvent('click', {bubbles: true, composed: true, cancelable: true, detail: 1}));")
    }

    func escribir(_ selector: String, _ valor: String) async {
        await evento(selector, "el.focus(); el.value = \(String(reflecting: valor)); el.dispatchEvent(new InputEvent('input', {bubbles: true, composed: true})); el.dispatchEvent(new FocusEvent('focusout', {bubbles: true, composed: true}));")
    }

    func sinteticos() async { _ = try? await js("return window.__kurthGrabadora.pruebas.sinteticos(true)", mundo: mundoGrabadora) }

    func grabar() async -> KurthWorkflow {
        print("── Grabar en la original")
        servir("original")
        grabando = true
        inicio = Date()
        var arranque = KurthWorkflowPaso(t: 0, tipo: .navegar)
        arranque.url = indice.absoluteString; arranque.tab = "A"; arranque.detalle = "inicio"
        await cargar(indice)
        pasos = [arranque]
        await sinteticos()
        await escribir("#q", "bolsa")
        await evento("#periodo", "el.selectedIndex = 1; el.dispatchEvent(new Event('change', {bubbles: true, composed: true}));")
        await evento("#envio", "el.click();")
        await clic("#filtrar")
        await clic("#fila-uf button")
        await clic(".barra button:nth-of-type(3)")
        await clic("a.link")
        let limite = Date().addingTimeInterval(5)
        while webView.url?.lastPathComponent != "detalle.html" || webView.isLoading, Date() < limite { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(150))
        await sinteticos()
        await escribir("#notas", "Revisar precios")
        await clic("button")
        try? await Task.sleep(for: .milliseconds(150))
        grabando = false

        var wf = KurthWorkflow(nombre: "ventas", titulo: "Ventas", descripcion: "prueba")
        wf.pasos = pasos
        wf.parametros = [KurthWorkflowParametro(nombre: "producto", descripcion: "Qué buscar", ejemplo: "bolsa")]
        let lineas = wf.pasos.map(KurthWorkflowsModelo.linea)
        let tipos = wf.pasos.map(\.tipo.rawValue)
        ok("se grabaron los 11 pasos", tipos == ["navegar", "escribir", "elegir", "marcar", "clic", "clic", "clic", "clic", "navegar", "escribir", "clic"],
           "\(tipos)\n   " + lineas.joined(separator: "\n   "))
        let editar = wf.pasos.first { $0.nombre == "Editar" }
        ok("el segundo «Editar» se graba con su orden y su posición", editar?.orden == 1 && editar?.pos?.count == 2,
           "orden \(String(describing: editar?.orden)) pos \(String(describing: editar?.pos))")
        ok("el campo se graba con su placeholder como nombre", wf.pasos.first { $0.tipo == .escribir }?.nombre == "Buscar producto")
        return wf
    }

    // MARK: - KurthReplayPagina (una sola vista, como una pestaña)

    var abierta = false
    var urlActual: String? { abierta ? webView.url?.absoluteString : nil }

    func abrir(_ url: String, clave: String?) async throws -> Bool {
        guard let u = URL(string: url) else { throw KurthReplayError("dirección no válida") }
        await cargar(u)
        abierta = true
        return false
    }

    func usar(_ clave: String?) -> Bool { abierta }
    func cerrar(_ clave: String?) {}

    func navegar(_ url: String) async throws {
        guard let u = URL(string: url) else { throw KurthReplayError("dirección no válida") }
        navegacionesDirectas += 1
        await cargar(u)
    }
    var navegacionesDirectas = 0

    func instalar() async throws {
        if try await js("return typeof window.__kurthReplay", mundo: mundoCopiloto) as? String == "object" { return }
        try await js(copiloto + "\nreturn true", mundo: mundoCopiloto)
        try await js(localizador + "\nreturn true", mundo: mundoCopiloto)
    }

    func esperarQuieta(maximo: Double) async {
        let limite = Date().addingTimeInterval(maximo)
        var anterior: String?
        while Date() < limite {
            if !webView.isLoading, (try? await instalar()) != nil,
               let q = try? await js("return JSON.stringify(window.__kurthReplay.quieto())", mundo: mundoCopiloto) as? String {
                if q == anterior, q.contains("\"complete\"") { return }
                anterior = q
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    func localizar(_ d: [String: Any]) async throws -> [String: Any] {
        if ProcessInfo.processInfo.environment["TRAZA"] != nil { print("     localizar \(d["nombre"] ?? "")") }
        try await instalar()
        return try await js("return window.__kurthReplay.localizar(d)", ["d": d], mundo: mundoCopiloto) as? [String: Any] ?? [:]
    }

    func actuar(_ a: KurthReplayAccion) async throws -> String {
        if ProcessInfo.processInfo.environment["TRAZA"] != nil { print("     actuar \(a)") }
        try await instalar()
        switch a {
        case .clic(let ref, _):
            return "\(try await js("return window.__kurth.clickJS(ref)", ["ref": ref], mundo: mundoCopiloto) ?? "")"
        case .escribir(let ref, let texto):
            return "\(try await js("return window.__kurth.typeJS(ref, t, true)", ["ref": ref, "t": texto], mundo: mundoCopiloto) ?? "")"
        case .elegir(let ref, let opcion):
            return "\(try await js("return window.__kurth.select(ref, o)", ["ref": ref, "o": opcion], mundo: mundoCopiloto) ?? "")"
        case .marcar(let ref, let valor):
            let r = try await js("return window.__kurth.formFill([{ref, valor}])", ["ref": ref, "valor": valor], mundo: mundoCopiloto) as? [String: Any]
            if let e = r?["error"] as? String { throw KurthReplayError(e) }
            return "marcado"
        case .tecla(let ref, let tecla, _):
            if let ref { try await js("return window.__kurthReplay.enfocar(ref)", ["ref": ref], mundo: mundoCopiloto) }
            return "\(try await js("return window.__kurth.keyJS(k, {})", ["k": tecla], mundo: mundoCopiloto) ?? "")"
        case .enviar(let ref):
            return "\(try await js("return window.__kurthReplay.enviar(ref)", ["ref": ref], mundo: mundoCopiloto) ?? "")"
        case .desplazar(let pantallas):
            return "\(try await js("return window.__kurthReplay.desplazar(p)", ["p": pantallas], mundo: mundoCopiloto) ?? "")"
        }
    }

    func antesDeActuar() {}

    // MARK: - 3 y 4. Repetir

    func acciones() async -> [String] { hechos }

    func correr(_ wf: KurthWorkflow, _ version: String, quitar: String? = nil,
                respaldo: ((KurthWorkflowPaso, Int, String) async -> KurthReplayRespaldo)? = nil) async -> (KurthReplayEjecutor.Resultado, [String], Double) {
        servir(version, quitar: quitar)
        abierta = false
        navegacionesDirectas = 0
        await cargar(URL(string: "about:blank")!)
        hechos = []
        let ejecutor = KurthReplayEjecutor(pagina: self)
        ejecutor.respaldo = respaldo
        if ProcessInfo.processInfo.environment["TRAZA"] != nil {
            ejecutor.alEmpezarPaso = { n, t in print("   · paso \(n)/\(t)") }
            ejecutor.alPaso = { r in print("   · \(r.indice) \(r.nivel.rawValue) \(r.ms) ms \(r.detalle ?? "")") }
        }
        let t0 = Date()
        let r = await ejecutor.correr(wf, valores: ["producto": "cartera"])
        return (r, await acciones(), Date().timeIntervalSince(t0))
    }

    func informe(_ r: KurthReplayEjecutor.Resultado) -> String {
        r.resumen + "\n   " + r.pasos.map { "\($0.indice). \($0.ok ? "✓" : "✗") \($0.nivel.rawValue)\($0.similitud.map { " \($0)" } ?? "") · \($0.ms) ms · \($0.descripcion)" + ($0.frase.map { " — \($0)" } ?? "") + ($0.detalle.map { " [\($0)]" } ?? "") }.joined(separator: "\n   ")
    }

    func todo() async {
        copiloto = (try? String(contentsOf: repo.appendingPathComponent("Nook/Kurth/KurthCopilot.js"), encoding: .utf8)) ?? ""
        localizador = (try? String(contentsOf: repo.appendingPathComponent("Nook/Kurth/KurthReplay.js"), encoding: .utf8)) ?? ""
        let grabadora = (try? String(contentsOf: repo.appendingPathComponent("Nook/Kurth/KurthGrabadora.js"), encoding: .utf8)) ?? ""
        ok("los tres scripts se leen", !copiloto.isEmpty && !localizador.isEmpty && !grabadora.isEmpty)
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(self, contentWorld: mundoGrabadora, name: "kurthGrabadora")
        config.userContentController.add(self, contentWorld: .page, name: "anotar")
        config.userContentController.addUserScript(WKUserScript(source: "// Nook kurth: grabadora de workflows\n" + grabadora,
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: mundoGrabadora))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        webView.navigationDelegate = self
        defer { try? FileManager.default.removeItem(at: sitio) }

        let wf = await grabar()

        print("── Similitud")
        await cargar(indice)
        try? await instalar()
        let sim = { (a: String, b: String) async -> Double in
            (try? await self.js("return window.__kurthReplay.pruebas.similitud(a, b)", ["a": a, "b": b], mundo: self.mundoCopiloto) as? NSNumber)?.doubleValue ?? -1
        }
        let s1 = await sim("Descargar informe", "Descargar reporte")
        let s2 = await sim("Descargar informe", "Limpiar")
        let s3 = await sim("Buscar producto", "Busca un producto")
        ok("«Descargar informe» ≈ «Descargar reporte» pasa el umbral", s1 >= 0.5, "\(s1)")
        ok("«Descargar informe» ≠ «Limpiar»", s2 < 0.3, "\(s2)")
        ok("«Buscar producto» ≈ «Busca un producto»", s3 >= 0.5, "\(s3)")

        print("── Repetir contra la misma página")
        let (r1, a1, t1) = await correr(wf, "original")
        let esperado = ["periodo:mes", "envio:true", "filtrar:cartera|mes|true", "editar:uf", "descargar", "guardar:Revisar precios"]
        ok("la original termina", r1.estado == .termino, informe(r1))
        ok("la original hace lo mismo que la grabación, con el parámetro", a1 == esperado, "\(a1)")
        let buscados = r1.pasos.filter { [.exacto, .normalizado, .etiqueta, .selector, .difuso, .posicion].contains($0.nivel) }
        ok("en la original todo lo buscado es exacto", !buscados.isEmpty && buscados.allSatisfy { $0.nivel == .exacto }, informe(r1))
        ok("la navegación del enlace no se repite a mano", r1.pasos.contains { $0.nivel == .yaEstaba } && navegacionesDirectas == 0, informe(r1))
        print("   (\(String(format: "%.1f", t1)) s)")

        print("── Repetir contra la cambiada (misma dirección)")
        let (r2, a2, t2) = await correr(wf, "cambiado")
        ok("la cambiada termina", r2.estado == .termino, informe(r2))
        ok("la cambiada hace lo mismo", a2 == esperado, "\(a2)\n   " + informe(r2))
        let nivel = { (nombre: String) in r2.pasos.first { $0.grabado == nombre || $0.descripcion.contains("«\(nombre)»") }?.nivel }
        ok("«Descargar informe» → «Descargar reporte» por difuso", nivel("Descargar informe") == .difuso, informe(r2))
        ok("el registro dice qué cambió", r2.pasos.contains { $0.frase == "Cambió de «Descargar informe» a «Descargar reporte»" }, informe(r2))
        ok("«Filtrar» movido de lugar y sin id: exacto", nivel("Filtrar") == .exacto, informe(r2))
        ok("«Periodo» → «Período»: normalizado", nivel("Periodo") == .normalizado, informe(r2))
        ok("«Incluir envío» → «Incluir envio»: normalizado", nivel("Incluir envío") == .normalizado, informe(r2))
        ok("«Ver detalle» de enlace a botón: normalizado", nivel("Ver detalle") == .normalizado, informe(r2))
        ok("el buscador con otro placeholder e id: difuso", nivel("Buscar producto") == .difuso, informe(r2))
        ok("el segundo «Editar» sigue siendo el de Ultrafemme", a2.contains("editar:uf") && !a2.contains("editar:krei"), "\(a2)")
        ok("cada paso trae su tiempo", r2.pasos.allSatisfy { $0.ms >= 0 } && r2.pasos.contains { $0.ms > 0 })
        print("   (\(String(format: "%.1f", t2)) s) Registro:\n   " + informe(r2))

        print("── Un paso que ya no existe")
        var llamadas: [Int] = []
        let (r3, a3, _) = await correr(wf, "cambiado", quitar: "Descargar reporte") { _, n, motivo in
            llamadas.append(n)
            return .fallo("en la prueba el agente no ayuda (\(motivo))")
        }
        let nDescargar = (wf.pasos.filter { !$0.esNarracion }.firstIndex { $0.nombre == "Descargar informe" } ?? -1) + 1
        ok("entra el respaldo en ese paso", llamadas == [nDescargar], "\(llamadas) vs \(nDescargar)")
        ok("la corrida falla en ese paso y lo dice", r3.estado == .fallo && r3.fallo == nDescargar && r3.resumen.contains("paso \(nDescargar)"), informe(r3))
        ok("lo anterior sí se hizo y lo siguiente no", a3.contains("editar:uf") && !a3.contains(where: { $0.hasPrefix("guardar") }), "\(a3)")

        print("── Respaldo que resuelve")
        let (r4, _, _) = await correr(wf, "cambiado", quitar: "Descargar reporte") { _, _, _ in .resuelto("lo hizo el agente") }
        ok("si el agente lo resuelve, sigue hasta el final", r4.estado == .termino && r4.pasos.contains { $0.nivel == .agente }, informe(r4))

        print("── Detener a media búsqueda")
        servir("cambiado")
        abierta = false
        await cargar(URL(string: "about:blank")!)
        let ejecutor = KurthReplayEjecutor(pagina: self)
        let tarea = Task { await ejecutor.correr(wf, valores: ["producto": "cartera"]) }
        try? await Task.sleep(for: .milliseconds(900)) // a media espera del difuso del paso 2
        tarea.cancel()
        let r6 = await tarea.value
        ok("detenida dice en qué paso, sin errores raros", r6.estado == .fallo && r6.resumen.hasPrefix("Detenida en el paso")
           && !informe(r6).contains("CancellationError"), informe(r6))

        print("── Contraseña")
        var conClave = wf
        var clave = KurthWorkflowPaso(t: 0.5, tipo: .escribir)
        clave.rol = "textbox"; clave.nombre = "Contraseña"; clave.valor = "«secreto»"; clave.secreto = true; clave.tab = "A"; clave.url = indice.absoluteString
        conClave.pasos.insert(clave, at: 1)
        var respaldos = 0
        let (r5, a5, _) = await correr(conClave, "original") { _, _, _ in respaldos += 1; return .fallo("no") }
        ok("un «secreto» detiene la corrida: necesita sesión", r5.estado == .fallo && r5.necesitaSesion && r5.fallo == 2 && r5.resumen.contains("inicies sesión"), informe(r5))
        ok("sin llamar al agente ni hacer nada más", respaldos == 0 && a5.isEmpty, "\(respaldos) \(a5)")
    }
}
