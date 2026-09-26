// Licensed under GPL-3.0. See LICENSE.
//
// Prueba de los workflows sin abrir Nook. Correr con kurth/checks/workflows.sh.
//  1. El modelo (Nook/Kurth/KurthWorkflowsModelo.swift): cómo se juntan los pasos, que ningún secreto
//     llegue al texto del agente, la programación (próxima corrida), la lectura de «Resultado: …»
//     y la tienda en disco (en una carpeta temporal).
//  2. El grabador (Nook/Kurth/KurthGrabadora.js) en un WKWebView sin ventana con workflows.html, en
//     el mismo mundo aislado que usa la app y con un canal que contesta como Nook. Los eventos se
//     simulan desde la página con `pruebas.sinteticos(true)`: en Nook solo cuentan los de verdad.
// Cada comprobación imprime ✅ o ❌; termina con 1 si alguna falló.
//
// No prueba lo que necesita Nook: pestañas y direcciones (Observation sobre TabsController), el
// micrófono y el dictado, el aviso, el popover, el envío al agente ni el temporizador real.

import AppKit
import WebKit

@main
struct WorkflowsCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let repo = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
            let prueba = Prueba(repo: repo)
            prueba.modelo()
            await prueba.grabador()
            print(prueba.fallas == 0 ? "\nTodo bien." : "\n\(prueba.fallas) fallas.")
            exit(prueba.fallas == 0 ? 0 : 1)
        }
        app.run()
    }
}

@MainActor
final class Prueba: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    let repo: URL
    var fallas = 0
    var mensajes: [[String: Any]] = []
    /// Todo lo que mandó el grabador en la prueba, aunque `mensajes` se vacíe entre pruebas.
    var historico: [[String: Any]] = []
    var holas = 0
    var webView: WKWebView!
    private var cargada: CheckedContinuation<Void, Never>?
    typealias M = KurthWorkflowsModelo

    init(repo: URL) { self.repo = repo }

    func ok(_ nombre: String, _ condicion: Bool, _ detalle: @autoclosure () -> String = "") {
        if condicion { print("✅ \(nombre)") } else { fallas += 1; print("❌ \(nombre)\n   \(detalle())") }
    }

    // MARK: - Modelo

    func paso(_ t: Double, _ tipo: KurthWorkflowPaso.Tipo, tab: String = "A", selector: String? = nil, nombre: String? = nil,
              valor: String? = nil, url: String? = nil, doble: Bool? = nil, secreto: Bool? = nil) -> KurthWorkflowPaso {
        var p = KurthWorkflowPaso(t: t, tipo: tipo)
        p.tab = tab; p.selector = selector; p.nombre = nombre; p.valor = valor; p.url = url; p.doble = doble; p.secreto = secreto
        return p
    }

    func modelo() {
        print("── Modelo")
        // Secretos
        ok("sanear tapa una tarjeta con espacios", M.sanear("Tarjeta 4111 1111 1111 1111 ok") == "Tarjeta «secreto» ok", M.sanear("Tarjeta 4111 1111 1111 1111 ok"))
        ok("sanear tapa una tarjeta con guiones", M.sanear("5555-5555-5555-4444") == "«secreto»")
        ok("sanear deja un teléfono", M.sanear("998 123 4567") == "998 123 4567")
        ok("sanear deja 16 dígitos que no pasan Luhn", M.sanear("1234567812345678") == "1234567812345678")
        ok("sanear deja un pedido corto", M.sanear("Pedido 12345") == "Pedido 12345")

        // Uniones
        var pasos: [KurthWorkflowPaso] = []
        M.agregar(paso(1, .escribir, selector: "#q", nombre: "Buscar", valor: "bol"), a: &pasos)
        M.agregar(paso(2, .escribir, selector: "#q", nombre: "Buscar", valor: "bolsa"), a: &pasos)
        ok("dos escrituras seguidas en el mismo campo son un paso", pasos.count == 1 && pasos[0].valor == "bolsa", "\(pasos.map(\.valor))")
        M.agregar(paso(3, .clic, selector: "#buscar", nombre: "Buscar"), a: &pasos)
        M.agregar(paso(4, .escribir, selector: "#q", nombre: "Buscar", valor: "cartera"), a: &pasos)
        ok("con un clic en medio son dos pasos", pasos.filter { $0.tipo == .escribir }.count == 2)
        M.agregar(paso(4.2, .clic, selector: "#fila", nombre: "Fila"), a: &pasos)
        M.agregar(paso(4.5, .clic, selector: "#fila", nombre: "Fila", doble: true), a: &pasos)
        ok("doble clic es un paso marcado doble", pasos.last?.doble == true && pasos.filter { $0.selector == "#fila" }.count == 1)
        M.agregar(paso(5, .navegar, url: "https://a.com/1"), a: &pasos)
        M.agregar(paso(5.8, .navegar, url: "https://a.com/login"), a: &pasos)
        ok("una redirección rápida se vuelve la dirección final", pasos.last?.url == "https://a.com/login" && pasos.filter { $0.tipo == .navegar }.count == 1)
        M.agregar(paso(10, .navegar, url: "https://a.com/2"), a: &pasos)
        ok("una navegación después de 2.5 s es otro paso", pasos.filter { $0.tipo == .navegar }.count == 2)
        M.agregar(paso(11, .pestañaNueva, tab: "B"), a: &pasos)
        M.agregar(paso(11.3, .cambiarPestaña, tab: "B"), a: &pasos)
        M.agregar(paso(11.6, .navegar, tab: "B", url: "https://b.com"), a: &pasos)
        ok("abrir pestaña, quedar en ella y su primera dirección son un paso",
           pasos.last?.tipo == .pestañaNueva && pasos.last?.url == "https://b.com" && !pasos.contains { $0.tipo == .cambiarPestaña })
        M.ponerTitulo("B shop", tab: "B", t: 12, en: &pasos)
        ok("el título llega después y se pone en su paso", pasos.last?.titulo == "B shop")
        var nar = paso(3.5, .voz, valor: "  aquí filtro por semana  ")
        nar.tab = nil
        M.agregar(nar, a: &pasos)
        let i = pasos.firstIndex { $0.tipo == .voz } ?? -1
        ok("la narración se acomoda por su hora", i > 0 && pasos[i - 1].t <= 3.5 && pasos[i + 1].t >= 3.5 && pasos[i].valor == "aquí filtro por semana")
        M.agregar(paso(13, .nota, valor: "   "), a: &pasos)
        ok("una nota vacía no se guarda", !pasos.contains { $0.tipo == .nota })
        M.agregar(paso(14, .escribir, selector: "#pass", nombre: "Contraseña", valor: "hunter2", secreto: true), a: &pasos)
        ok("un paso secreto guarda «secreto», nunca el valor", pasos.last?.valor == "«secreto»")
        M.agregar(paso(15, .escribir, selector: "#notas", nombre: "Notas", valor: "paga con 4111111111111111"), a: &pasos)
        ok("una tarjeta en un campo normal se tapa", pasos.last?.valor == "paga con «secreto»", pasos.last?.valor ?? "")

        var wf = KurthWorkflow(nombre: "reporte-krei", titulo: "Reporte Krei", descripcion: "Baja ventas")
        wf.pasos = pasos
        wf.duracion = 75
        let md = M.markdown(wf)
        ok("el texto para el agente no trae secretos", !md.contains("hunter2") && !md.contains("4111"), md)
        ok("el texto trae la narración", md.contains("Kurth dice [0:03]: «aquí filtro por semana»"), md)
        ok("el texto numera y dice la pestaña", md.contains("1. [0:01 · pestaña 1] Escribe «bolsa»"), md)
        ok("el texto trae el selector de respaldo", md.contains("respaldo: `#buscar`"), md)
        let skill = M.instruccionesParaSkill(wf, rutaJSON: "/tmp/x.json", reemplaza: false)
        ok("las instrucciones piden nook-workflow y define", skill.contains("nook-workflow: true") && skill.contains("kurth_workflow: action define"), skill)
        wf.parametros = [KurthWorkflowParametro(nombre: "semana", descripcion: "Semana", ejemplo: "38")]
        wf.ultimosValores = ["semana": "39"]
        let correr = M.instruccionesParaCorrer(wf, valores: [:], programada: true, rutaJSON: "/tmp/x.json")
        ok("correr usa el último valor y pide pestaña en segundo plano", correr.contains("- semana: «39»") && correr.contains("en segundo plano"), correr)
        ok("el globo dice el parámetro", M.textoVisibleDeCorrida(wf, valores: ["semana": "40"], programada: false) == "Ejecuta «Reporte Krei» · semana: 40")

        // Resultado
        let r1 = M.resultado(de: "Listo.\n\n**Resultado: terminó — Mandé 3 correos**")
        ok("lee «Resultado: terminó» en negritas", r1?.estado == .termino && r1?.resumen == "Mandé 3 correos", "\(String(describing: r1))")
        let r2 = M.resultado(de: "Resultado: fallo - no cargó la página")
        ok("lee «fallo» sin acento", r2?.estado == .fallo && r2?.resumen == "no cargó la página", "\(String(describing: r2))")
        ok("lee «Esperando»", M.resultado(de: "resultado: Esperando — confirma el envío")?.estado == .esperando)
        ok("sin línea de resultado es nil", M.resultado(de: "Ya quedó") == nil)

        // Programación
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Cancun")!
        cal.locale = Locale(identifier: "es_MX")
        func fecha(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: d, hour: h, minute: m))! }
        let sabado10 = fecha(26, 10)
        var diario = KurthWorkflowProgramacion(frecuencia: .diario)
        diario.hora = 9
        ok("diario 9:00 desde el sábado 10:00 → domingo 9:00", diario.siguiente(despuesDe: sabado10, calendario: cal) == fecha(27, 9))
        ok("diario 9:00 desde las 8:00 → hoy 9:00", diario.siguiente(despuesDe: fecha(26, 8), calendario: cal) == fecha(26, 9))
        var dias = KurthWorkflowProgramacion(frecuencia: .dias)
        dias.dias = [2, 4]
        dias.hora = 9
        ok("lun y mié 9:00 desde el sábado → lunes 28", dias.siguiente(despuesDe: sabado10, calendario: cal) == fecha(28, 9))
        var cada = KurthWorkflowProgramacion(frecuencia: .cadaHoras)
        cada.cadaHoras = 4
        cada.desde = sabado10
        ok("cada 4 h desde las 10:00, a las 15:30 → 18:00", cada.siguiente(despuesDe: fecha(26, 15, 30), calendario: cal) == fecha(26, 18))
        var una = KurthWorkflowProgramacion(frecuencia: .unaVez)
        una.fecha = fecha(26, 9)
        ok("una vez en el pasado no tiene próxima", una.siguiente(despuesDe: sabado10, calendario: cal) == nil)
        do {
            let p = try M.programacion(desde: ["frecuencia": "dias", "dias": ["lun", "mié"], "hora": "07:30"], calendario: cal)
            ok("la regla del MCP entiende días y hora", p.dias == [2, 4] && p.hora == 7 && p.minuto == 30)
            let u = try M.programacion(desde: ["frecuencia": "una-vez", "fecha": "2026-09-27T09:00"], calendario: cal)
            ok("la regla del MCP entiende una fecha local", u.fecha == fecha(27, 9))
        } catch {
            ok("la regla del MCP", false, error.localizedDescription)
        }
        ok("una hora imposible se rechaza", (try? M.programacion(desde: ["frecuencia": "diario", "hora": "25:00"])) == nil)
        ok("sin frecuencia se rechaza", (try? M.programacion(desde: ["hora": "09:00"])) == nil)
        ok("cuándo: mañana", M.cuando(fecha(27, 9), ahora: sabado10, calendario: cal) == "mañana 9:00", M.cuando(fecha(27, 9), ahora: sabado10, calendario: cal))
        ok("cuándo: ayer", M.cuando(fecha(25, 9), ahora: sabado10, calendario: cal) == "ayer 9:00")
        ok("describir: entre semana", { var p = KurthWorkflowProgramacion(frecuencia: .dias); p.dias = [2, 3, 4, 5, 6]; return M.describir(p, calendario: cal) }() == "Entre semana 9:00")
        ok("describir: lun y mié", M.describir(dias, calendario: cal) == "Lun y mié 9:00", M.describir(dias, calendario: cal))

        // Tienda
        let carpeta = FileManager.default.temporaryDirectory.appendingPathComponent("kurth-workflows-\(UUID().uuidString)")
        let tienda = KurthWorkflowsTienda(carpeta: carpeta)
        do {
            var guardado = wf
            guardado.programacion = dias
            guardado.corridas = (0..<25).map { KurthWorkflowCorrida(inicio: Date().addingTimeInterval(Double($0)), estado: .termino, programada: false) }
            try tienda.guardar(guardado)
            let leido = tienda.cargar("reporte-krei")
            ok("la tienda guarda y lee", leido?.pasos == guardado.pasos && leido?.programacion?.dias == [2, 4])
            ok("la tienda guarda solo las últimas 20 corridas", leido?.corridas.count == 20)
            let crudo = try String(contentsOf: tienda.ruta("reporte-krei"), encoding: .utf8)
            ok("el JSON no trae secretos", !crudo.contains("hunter2") && !crudo.contains("4111"))
            // Un JSON de una versión anterior, con lo mínimo.
            try #"{"nombre":"viejo","pasos":[]}"#.write(to: tienda.ruta("viejo"), atomically: true, encoding: .utf8)
            ok("un JSON viejo con lo mínimo se lee", tienda.cargar("viejo")?.titulo == "viejo")
            ok("todos() lista los dos", tienda.todos().count == 2)
            try tienda.borrar("viejo")
            ok("borrar quita el archivo", !tienda.existe("viejo"))
        } catch {
            ok("la tienda", false, error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: carpeta)
    }

    // MARK: - Grabador

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                           replyHandler: @escaping (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            let cuerpo = message.body as? [String: Any] ?? [:]
            if cuerpo["tipo"] as? String == "hola" {
                holas += 1
                replyHandler(["grabando": true], nil)
                return
            }
            if let paso = cuerpo["paso"] as? [String: Any] { mensajes.append(paso); historico.append(paso) }
            replyHandler(nil, nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { cargada?.resume(); cargada = nil }
    }

    let mundo = WKContentWorld.world(name: "KurthGrabadora")

    @discardableResult
    func js(_ codigo: String, mundo m: WKContentWorld? = nil) async -> Any? {
        do { return try await webView.callAsyncJavaScript(codigo, arguments: [:], in: nil, contentWorld: m ?? mundo) }
        catch { return "ERROR: \((error as NSError).userInfo["WKJavaScriptExceptionMessage"] ?? error.localizedDescription)" }
    }

    /// Corre en la página (no en el mundo del grabador), como lo haría el sitio, y espera a que lleguen los mensajes.
    func pagina(_ codigo: String, espera: Int = 120) async -> [[String: Any]] {
        let antes = mensajes.count
        await js(codigo, mundo: .page)
        try? await Task.sleep(for: .milliseconds(espera))
        return Array(mensajes[antes...])
    }

    func grabador() async {
        print("── Grabador")
        let fuente = (try? String(contentsOf: repo.appendingPathComponent("Nook/Kurth/KurthGrabadora.js"), encoding: .utf8)) ?? ""
        ok("KurthGrabadora.js se lee", !fuente.isEmpty)
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(self, contentWorld: mundo, name: "kurthGrabadora")
        config.userContentController.addUserScript(WKUserScript(source: "// Nook kurth: grabadora de workflows\n" + fuente,
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: mundo))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
        webView.navigationDelegate = self
        await withCheckedContinuation { c in
            cargada = c
            let html = repo.appendingPathComponent("kurth/checks/workflows.html")
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        try? await Task.sleep(for: .milliseconds(200))
        let activo = await js("return window.__kurthGrabadora.activo") as? Bool
        ok("al cargar pregunta a Nook y se activa", holas == 1 && activo == true, "holas \(holas), activo \(String(describing: activo))")
        let visto = await js("return typeof window.__kurthGrabadora", mundo: .page) as? String
        ok("la página no ve al grabador", visto == "undefined", visto ?? "")

        // Sin sintéticos, un clic simulado no es de Kurth.
        var r = await pagina("document.querySelector('#buscar span').dispatchEvent(new MouseEvent('click', {bubbles: true, composed: true, detail: 1}))")
        ok("un clic que la página se da a sí misma no se graba", r.isEmpty, "\(r)")
        await js("window.__kurthGrabadora.pruebas.sinteticos(true); return true")

        func uno(_ lista: [[String: Any]], _ tipo: String) -> [String: Any]? { lista.first { $0["tipo"] as? String == tipo } }

        r = await pagina("document.querySelector('#buscar span').dispatchEvent(new MouseEvent('click', {bubbles: true, composed: true, detail: 1}))")
        let clic = uno(r, "clic")
        ok("clic en el ícono de un botón graba el botón", clic?["rol"] as? String == "button" && clic?["nombre"] as? String == "Buscar"
           && clic?["selector"] as? String == "#buscar", "\(r)")

        r = await pagina("""
            const q = document.getElementById('q');
            q.value = 'bol'; q.dispatchEvent(new InputEvent('input', {bubbles: true, composed: true}));
            q.value = 'bolsa'; q.dispatchEvent(new InputEvent('input', {bubbles: true, composed: true}));
            q.dispatchEvent(new FocusEvent('focusout', {bubbles: true, composed: true}));
            """)
        let escrito = uno(r, "escribir")
        ok("escribir en un campo es un paso con el valor final y su etiqueta", r.count == 1 && escrito?["valor"] as? String == "bolsa"
           && escrito?["nombre"] as? String == "Buscar en Krei" && escrito?["selector"] as? String == "#q", "\(r)")

        r = await pagina("""
            const p = document.getElementById('pass');
            p.value = 'hunter2'; p.dispatchEvent(new InputEvent('input', {bubbles: true, composed: true}));
            p.dispatchEvent(new FocusEvent('focusout', {bubbles: true, composed: true}));
            """)
        ok("una contraseña se graba como «secreto»", uno(r, "escribir")?["valor"] as? String == "«secreto»" && uno(r, "escribir")?["secreto"] as? Bool == true, "\(r)")

        r = await pagina("""
            const n = document.getElementById('notas');
            n.value = '4111 1111 1111 1111'; n.dispatchEvent(new InputEvent('input', {bubbles: true, composed: true}));
            n.dispatchEvent(new FocusEvent('focusout', {bubbles: true, composed: true}));
            """)
        ok("un número de tarjeta en un campo normal es secreto", uno(r, "escribir")?["valor"] as? String == "«secreto»", "\(r)")

        r = await pagina("""
            const c = document.getElementById('clave2');
            c.dispatchEvent(new FocusEvent('focusin', {bubbles: true, composed: true}));
            c.type = 'text';
            c.value = 'visible123'; c.dispatchEvent(new InputEvent('input', {bubbles: true, composed: true}));
            c.dispatchEvent(new FocusEvent('focusout', {bubbles: true, composed: true}));
            """)
        ok("una contraseña que la página mostró como texto sigue siendo secreto", uno(r, "escribir")?["valor"] as? String == "«secreto»", "\(r)")

        r = await pagina("""
            const s = document.getElementById('periodo');
            s.selectedIndex = 1; s.dispatchEvent(new Event('change', {bubbles: true, composed: true}));
            """)
        ok("una lista graba la opción elegida", uno(r, "elegir")?["valor"] as? String == "Semana pasada", "\(r)")

        r = await pagina("""
            document.getElementById('lab-envio').dispatchEvent(new MouseEvent('click', {bubbles: true, composed: true, detail: 1}));
            """)
        ok("casilla por su etiqueta: un paso «marcar», sin clic de más", r.count == 1 && uno(r, "marcar")?["valor"] as? String == "sí"
           && (uno(r, "marcar")?["nombre"] as? String ?? "").contains("Incluir envío"), "\(r)")

        r = await pagina("""
            const co = document.getElementById('correo');
            co.value = 'hola@krei.mx'; co.dispatchEvent(new InputEvent('input', {bubbles: true, composed: true}));
            co.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true, composed: true}));
            document.getElementById('f1').dispatchEvent(new SubmitEvent('submit', {bubbles: true, cancelable: true}));
            """)
        ok("Enter en un campo: primero su valor, luego la tecla, y el envío no se repite",
           r.map { $0["tipo"] as? String ?? "" } == ["escribir", "tecla"] && uno(r, "tecla")?["tecla"] as? String == "Enter", "\(r)")

        r = await pagina("document.getElementById('f2').dispatchEvent(new SubmitEvent('submit', {bubbles: true, cancelable: true}))")
        ok("un envío sin clic ni Enter se graba", uno(r, "enviar")?["nombre"] as? String == "Suscripción", "\(r)")

        r = await pagina("""
            document.getElementById('q').dispatchEvent(new KeyboardEvent('keydown', {key: 'c', metaKey: true, bubbles: true, composed: true}));
            document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'k', metaKey: true, bubbles: true, composed: true}));
            """)
        ok("⌘C en un campo no; ⌘K fuera sí", r.count == 1 && uno(r, "tecla")?["tecla"] as? String == "⌘K", "\(r)")

        r = await pagina("document.querySelector('a').dispatchEvent(new MouseEvent('click', {bubbles: true, composed: true, detail: 1, cancelable: true}))")
        ok("un enlace se graba con su data-testid y su destino", uno(r, "clic")?["selector"] as? String == "a[data-testid=\"ventas-link\"]"
           && (uno(r, "clic")?["href"] as? String ?? "").hasSuffix("/ventas") && uno(r, "clic")?["rol"] as? String == "link", "\(r)")
        await js("document.querySelector('a').addEventListener('click', e => e.preventDefault()); return true", mundo: .page)

        r = await pagina("""
            document.getElementById('tarjeta-krei').dispatchEvent(new MouseEvent('click', {bubbles: true, composed: true, detail: 1}));
            document.getElementById('parrafo').dispatchEvent(new MouseEvent('click', {bubbles: true, composed: true, detail: 1}));
            """)
        ok("un div con cursor de mano sí; un párrafo no", r.count == 1 && uno(r, "clic")?["nombre"] as? String == "Abrir tarjeta", "\(r)")

        r = await pagina("document.getElementById('react-123456').dispatchEvent(new MouseEvent('click', {bubbles: true, composed: true, detail: 1}))")
        let sel = uno(r, "clic")?["selector"] as? String ?? ""
        ok("un id generado no se usa como selector", !sel.contains("123456") && !sel.isEmpty, sel)

        r = await pagina("""
            const b = document.getElementById('buscar');
            b.dispatchEvent(new MouseEvent('click', {bubbles: true, composed: true, detail: 1}));
            b.dispatchEvent(new MouseEvent('click', {bubbles: true, composed: true, detail: 2}));
            """)
        ok("el segundo clic de un doble clic viene marcado", r.count == 2 && r[1]["doble"] as? Bool == true, "\(r)")

        // WebKit sin ventana entrega los eventos de scroll de verdad tarde; se deja asentar antes de cada prueba.
        func asentar() async { await js("window.scrollTo(0, 0); return true", mundo: .page); try? await Task.sleep(for: .milliseconds(900)); mensajes.removeAll() }
        await asentar()
        r = await pagina("""
            window.dispatchEvent(new Event('scroll'));
            window.scrollTo(0, 100); window.dispatchEvent(new Event('scroll'));
            """, espera: 900)
        ok("un scroll chico no se graba", r.isEmpty, "\(r)")
        await asentar()
        r = await pagina("""
            window.dispatchEvent(new Event('scroll'));
            window.scrollTo(0, document.getElementById('abajo').offsetTop - 100); window.dispatchEvent(new Event('scroll'));
            """, espera: 900)
        let scroll = uno(r, "scroll")
        ok("un scroll grande se graba con dirección y cuánto", r.count == 1 && scroll?["valor"] as? String == "abajo"
           && (scroll?["detalle"] as? String ?? "").contains("pantallas"), "\(r)")
        ok("el scroll dice el encabezado cercano", scroll?["nombre"] as? String == "Precios", "\(r)")
        await js("return window.__kurthGrabadora.desactivar()")
        r = await pagina("document.querySelector('#buscar span').dispatchEvent(new MouseEvent('click', {bubbles: true, composed: true, detail: 1}))")
        ok("apagado no graba nada", r.isEmpty, "\(r)")
        let todo = "\(historico)"
        ok("ningún mensaje trae una contraseña o una tarjeta", !historico.isEmpty && !todo.contains("hunter2") && !todo.contains("4111")
           && !todo.contains("visible123"))
    }
}
