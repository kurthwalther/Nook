// Licensed under GPL-3.0. See LICENSE.
//
// Prueba de la traducción de páginas sin abrir Nook ni descargar idiomas: un WKWebView carga
// traduccion.html, se instala KurthTraduccion.js en el mismo mundo aislado que usa la app y se
// corre el mismo bucle que KurthTraduccion.swift (tomar → peticiones → repartir → aplicar) con un
// traductor falso que pasa el texto a mayúsculas. Las respuestas falsas se construyen con el init
// público de TranslationSession.Response, así que KurthTraduccionLotes.swift es el que se envía.
// Correr con kurth/checks/traduccion.sh. Cada comprobación imprime ✅ o ❌; termina con 1 si falla.
//
// No prueba: el modelo de Apple de verdad (¿conserva las marcas de la frase atribuida?), la hoja
// de descarga, ni el botón. Eso necesita Nook y un par de idiomas instalado.

import AppKit
import WebKit
import Translation

@MainActor final class Canal: NSObject, WKScriptMessageHandler {
    var avisos = 0
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { avisos += 1 }
}

@main
@MainActor
struct Check {
    static var fallas = 0
    static var webView: WKWebView!
    static let mundo = WKContentWorld.world(name: "KurthCopilot")
    static let canal = Canal()
    static var lotesVistos: [[String: Any]] = []
    static var atribuidas = 0, porPartes = 0, segundaVuelta = 0

    static func ok(_ nombre: String, _ condicion: Bool, _ detalle: String = "") {
        if condicion { print("✅ \(nombre)") } else { fallas += 1; print("❌ \(nombre)\n   \(detalle)") }
    }

    static func js(_ codigo: String, _ args: [String: Any] = [:], mundo m: WKContentWorld? = nil) async throws -> Any? {
        do { return try await webView.callAsyncJavaScript(codigo, arguments: args, in: nil, contentWorld: m ?? mundo) }
        catch {
            let ns = error as NSError
            throw NSError(domain: "js", code: 1, userInfo: [NSLocalizedDescriptionKey: ns.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription])
        }
    }
    static func pagina(_ codigo: String) async throws -> Any? { try await js(codigo, mundo: .page) }
    static func texto(_ id: String) async throws -> String {
        try await pagina("return document.getElementById('\(id)').textContent") as? String ?? "?"
    }

    static func esperar(_ segundos: Double = 3, _ condicion: () -> Bool) async -> Bool {
        let limite = Date().addingTimeInterval(segundos)
        while !condicion() && Date() < limite { try? await Task.sleep(for: .milliseconds(30)) }
        return condicion()
    }

    /// El traductor falso: mayúsculas. Con `conservarMarcas`, la frase atribuida regresa con sus
    /// atributos por tramo (lo que se espera del modelo); sin él, en un solo tramo sin marcas.
    static func falsa(_ reqs: [TranslationSession.Request], conservarMarcas: Bool) -> [TranslationSession.Response] {
        let en = Locale.Language(identifier: "en"), es = Locale.Language(identifier: "es-MX")
        return reqs.map { r in
            if #available(macOS 26.4, *), let a = r.attributedSourceText {
                var fuera = AttributedString()
                if conservarMarcas {
                    for run in a.runs {
                        var s = AttributedString(String(a[run.range].characters).uppercased())
                        s.mergeAttributes(run.attributes)
                        fuera += s
                    }
                } else {
                    fuera = AttributedString(String(a.characters).uppercased())
                }
                return TranslationSession.Response(sourceLanguage: en, targetLanguage: es, sourceAttributedText: a,
                                                   targetAttributedText: fuera, clientIdentifier: r.clientIdentifier)
            }
            return TranslationSession.Response(sourceLanguage: en, targetLanguage: es, sourceText: r.sourceText,
                                               targetText: r.sourceText.uppercased(), clientIdentifier: r.clientIdentifier)
        }
    }

    /// El bucle de KurthTraduccion.bombear, con el traductor falso.
    static func bombear(conservarMarcas: Bool = true) async throws {
        while true {
            let lote = try await js("return window.__kurthTrad.tomar(40)") as? [[String: Any]] ?? []
            if lote.isEmpty { break }
            lotesVistos += lote
            let us = lote.compactMap(KurthUnidadDeTraduccion.init)
            var rep = KurthLotes.repartir(us, falsa(KurthLotes.peticiones(us, atribuidas: true), conservarMarcas: conservarMarcas), atribuidas: true)
            if !rep.sinRepartir.isEmpty {
                segundaVuelta += rep.sinRepartir.count
                let rep2 = KurthLotes.repartir(rep.sinRepartir, falsa(rep.sinRepartir.flatMap(KurthLotes.porPartes), conservarMarcas: true), atribuidas: false)
                rep.resultados.merge(rep2.resultados) { $1 }
                rep.porPartes += rep2.porPartes
            }
            atribuidas += rep.atribuidas; porPartes += rep.porPartes
            _ = try await js("return window.__kurthTrad.aplicar(r)", ["r": KurthLotes.paraJS(rep.resultados)])
        }
    }

    /// Espera el aviso de la página (IntersectionObserver o MutationObserver) y traduce.
    static func tras(_ accion: String, conservarMarcas: Bool = true) async throws -> Bool {
        let antes = canal.avisos
        if !accion.isEmpty { _ = try await pagina(accion) }
        let llego = await esperar { canal.avisos > antes }
        try await bombear(conservarMarcas: conservarMarcas)
        return llego
    }

    static func main() async {
        let repo = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
        let fuente = try! String(contentsOf: repo.appendingPathComponent("Nook/Kurth/KurthTraduccion.js"), encoding: .utf8)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        // Fuera de la pantalla: sin ventana, WebKit no corre IntersectionObserver (no hay pintado).
        let ventana = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 800),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        ventana.contentView = webView
        ventana.orderBack(nil)

        webView.loadFileURL(repo.appendingPathComponent("kurth/checks/traduccion.html"), allowingReadAccessTo: repo.appendingPathComponent("kurth/checks"))
        _ = await esperar(10) { !webView.isLoading }
        try? await Task.sleep(for: .milliseconds(200))

        do {
            // El canal se registra después de cargar, como en la app (al primer uso).
            webView.configuration.userContentController.add(canal, contentWorld: mundo, name: "kurthTraduccion")
            _ = try await js(fuente + "\nreturn true")
            ok("script instalado", try await js("return typeof window.__kurthTrad") as? String == "object")

            // ── muestra para detectar el idioma ─────────────────────────────────────────────
            let m = try await js("return window.__kurthTrad.muestra(2000)") as? [String: Any] ?? [:]
            let muestra = m["texto"] as? String ?? ""
            ok("muestra trae el lang declarado", m["lang"] as? String == "en", "\(m)")
            ok("muestra trae texto de lectura", muestra.contains("Welcome to the store") && muestra.contains("privacy policy"), muestra)
            ok("muestra no trae código", !muestra.contains("npm install"), muestra)

            // ── primera pasada: lo que se ve ────────────────────────────────────────────────
            let est = try await js("return window.__kurthTrad.activar()") as? [String: Any] ?? [:]
            ok("activar arma unidades", ((est["unidades"] as? [String: Any])?["total"] as? Int ?? 0) >= 10, "\(est)")
            ok("el canal agregado después de cargar sí recibe", try await tras(""))

            ok("título traducido", try await texto("titulo") == "WELCOME TO THE STORE", try await texto("titulo"))
            ok("frase con link traducida entera", try await texto("frase") == "READ OUR PRIVACY POLICY FOR MORE DETAILS.", try await texto("frase"))
            ok("el link sigue siendo link", try await pagina("const a = document.getElementById('link'); return a && a.parentNode.id === 'frase' && a.href === 'https://example.com/privacy'") as? Bool == true)
            let frase = lotesVistos.first { (($0["partes"] as? [Any])?.first as? String) == "Read our" }
            let segs = (frase?["segs"] as? [[Any]])?.map { $0[0] as? String ?? "" }.joined() ?? ""
            ok("la frase viaja completa con sus tramos", segs == "Read our privacy policy for more details.", "segs: \(segs)")
            ok("la ruta atribuida se usó", atribuidas >= 1, "atribuidas \(atribuidas)")
            let juntos = lotesVistos.contains { l in
                let p = (l["partes"] as? [Any])?.compactMap { $0 as? String } ?? []
                return p.contains("Home") && p.contains("About us")
            }
            ok("links con display:block no se pegan en una unidad", !juntos)
            ok("menú traducido", try await texto("menu") == "HOMEABOUT US", try await texto("menu"))
            ok("<br> corta la unidad", try await pagina("return document.getElementById('saltos').innerHTML") as? String == "FIRST LINE<br>SECOND LINE")
            ok("<code> no se toca", try await pagina("return document.getElementById('codigo').innerHTML") as? String == "RUN <code>npm install</code> BEFORE STARTING.",
               try await pagina("return document.getElementById('codigo').innerHTML") as? String ?? "")
            ok("translate=no no se toca", try await texto("no") == "Brand Name Inc")
            ok(".notranslate no se toca", try await texto("no2") == "Keep this text")
            ok("contenteditable no se toca", try await texto("editable") == "Editable draft text")
            ok("sin letras no se toca", try await texto("simbolos") == "· | 2026")
            ok("placeholder traducido", try await pagina("return document.getElementById('buscar').placeholder") as? String == "SEARCH PRODUCTS")
            ok("espacio de las orillas se respeta", try await texto("espacios") == "   SPACED TEXT HERE   ", "«\(try await texto("espacios"))»")
            ok("lo de abajo del pliegue espera", try await texto("lejos") == "Far below the fold")

            // ── scroll, contenido nuevo y cambios de la página ─────────────────────────────
            ok("al hacer scroll llega el aviso", try await tras("document.getElementById('lejos').scrollIntoView(); return true"))
            ok("lo de abajo se traduce al llegar", try await texto("lejos") == "FAR BELOW THE FOLD", try await texto("lejos"))
            ok("contenido nuevo avisa", try await tras("document.getElementById('dinamico').innerHTML = '<p id=nuevo>New content arrived</p>'; return true"))
            ok("contenido nuevo se traduce", try await texto("nuevo") == "NEW CONTENT ARRIVED", try await texto("nuevo"))
            ok("texto cambiado por la página avisa", try await tras("document.getElementById('cambia').firstChild.data = 'New value from page'; return true"))
            ok("texto cambiado por la página se retraduce", try await texto("cambia") == "NEW VALUE FROM PAGE", try await texto("cambia"))

            // ── ver original ───────────────────────────────────────────────────────────────
            _ = try await js("return window.__kurthTrad.original()")
            ok("original: frase", try await texto("frase") == "Read our privacy policy for more details.", try await texto("frase"))
            ok("original: título", try await texto("titulo") == "Welcome to the store")
            ok("original: espacios exactos", try await texto("espacios") == "   Spaced   text here   ", "«\(try await texto("espacios"))»")
            ok("original: placeholder", try await pagina("return document.getElementById('buscar').placeholder") as? String == "Search products")
            ok("original: contenido nuevo", try await texto("nuevo") == "New content arrived")
            ok("original: lo de la página manda", try await texto("cambia") == "New value from page", try await texto("cambia"))
            ok("original: inactiva", (try await js("return window.__kurthTrad.estado()") as? [String: Any])?["activa"] as? Bool == false)
            let avisosQuietos = canal.avisos
            _ = try await pagina("document.getElementById('dinamico').innerHTML += '<p>After original</p>'; return true")
            try? await Task.sleep(for: .milliseconds(400))
            ok("sin traducción activa no hay avisos", canal.avisos == avisosQuietos)

            // ── el modelo pierde las marcas: segunda vuelta por partes ───────────────────
            _ = try await pagina("window.scrollTo(0, 0); return true")
            try? await Task.sleep(for: .milliseconds(100))
            let antesSegunda = segundaVuelta
            _ = try await js("return window.__kurthTrad.activar()")
            _ = try await tras("", conservarMarcas: false)
            ok("sin marcas cae a por partes", segundaVuelta > antesSegunda, "segunda vuelta \(segundaVuelta - antesSegunda)")
            ok("sin marcas la estructura sigue", try await texto("frase") == "READ OUR PRIVACY POLICY FOR MORE DETAILS.", try await texto("frase"))
            ok("sin marcas el link sigue", try await pagina("return document.getElementById('link').textContent") as? String == "PRIVACY POLICY")
        } catch {
            fallas += 1
            print("❌ excepción: \(error.localizedDescription)")
        }
        print(fallas == 0 ? "\nTodo bien." : "\n\(fallas) fallas.")
        exit(fallas == 0 ? 0 : 1)
    }
}
