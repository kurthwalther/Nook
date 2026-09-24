// Licensed under GPL-3.0. See LICENSE.
//
//  KurthCopilot.swift
//  Nook (rama kurth)
//
//  Herramientas de "copiloto" para el agente, por el MCP de desarrollo (DevMCPServer):
//  foto de la página con referencias (@e1…), click, escribir, teclas, hover, scroll, listas,
//  diálogos y pestañas por `tabId`. Kurth las pidió el 24 sep a partir de una lista de otro chat.
//
//  Dos modos por acción, y el resultado dice cuál se usó:
//   - nativo: eventos de mouse y teclado mandados directo a la vista web (NSEvent a
//     mouseDown/keyDown del WKWebView). La página los recibe como de una persona
//     (isTrusted = true), así que funcionan en sitios que ignoran los clicks de JavaScript y en
//     React sin trucos. Requiere que la pestaña esté a la vista en una ventana.
//   - javascript: respaldo para pestañas sin ventana (la del agente en segundo plano) o si el
//     nativo no llegó. Lo hace KurthCopilot.js en un mundo aislado.
//  El click nativo se comprueba: el JS arma una sonda que anota el siguiente click y si fue humano;
//  si no llegó, se repite por JavaScript.
//

import AppKit
import WebKit
import NookSettings
import NookWeb

@MainActor
enum KurthCopilot {

    // MARK: - Definiciones

    private static let tabId: [String: Any] = [
        "type": "string",
        "description": "Id de la pestaña (de list_tabs u open_tab). Sin él, la pestaña activa de la ventana activa.",
    ]
    private static let ref: [String: Any] = ["type": "string", "description": "Referencia de snapshot, p. ej. \"e12\" o \"@e12\"."]

    static let tools: [AIToolDefinition] = [
        AIToolDefinition(
            name: "snapshot",
            description: "Foto de texto de la página: cada elemento con el que se puede interactuar, con su referencia (@e1, @e2…), nombre y estado, más los encabezados. Tómala antes de actuar y otra vez si la página cambió. Las referencias duran mientras el elemento siga en la página.",
            parameters: ["type": "object", "properties": ["tabId": tabId, "max": ["type": "integer", "description": "Máximo de elementos (por defecto 400)."]]]
        ),
        AIToolDefinition(
            name: "click",
            description: "Click en un elemento por su referencia. Nativo (la página lo ve como humano) si la pestaña está a la vista; si no, por JavaScript. doble: true para doble click.",
            parameters: ["type": "object", "properties": ["tabId": tabId, "ref": ref, "doble": ["type": "boolean"]], "required": ["ref"]]
        ),
        AIToolDefinition(
            name: "type_text",
            description: "Escribe en un campo (input, textarea o editable) por su referencia. limpiar: true borra lo que tenga antes. enviar: true presiona Enter al final. Funciona en sitios con React.",
            parameters: ["type": "object", "properties": [
                "tabId": tabId, "ref": ref, "texto": ["type": "string"],
                "limpiar": ["type": "boolean"], "enviar": ["type": "boolean"],
            ], "required": ["ref", "texto"]]
        ),
        AIToolDefinition(
            name: "press_key",
            description: "Presiona una tecla en la pestaña: Enter, Tab, Escape, Backspace, Delete, ArrowUp/Down/Left/Right, Home, End, PageUp, PageDown, Space, o un carácter. modificadores: cmd, shift, alt, ctrl.",
            parameters: ["type": "object", "properties": [
                "tabId": tabId, "tecla": ["type": "string"],
                "modificadores": ["type": "array", "items": ["type": "string"]],
            ], "required": ["tecla"]]
        ),
        AIToolDefinition(
            name: "hover",
            description: "Pasa el mouse sobre un elemento (abre menús que se despliegan al pasar encima).",
            parameters: ["type": "object", "properties": ["tabId": tabId, "ref": ref], "required": ["ref"]]
        ),
        AIToolDefinition(
            name: "scroll",
            description: "Desplaza la página, o un elemento con scroll propio si das ref. dy positivo baja; dx positivo va a la derecha. Por defecto baja casi una pantalla.",
            parameters: ["type": "object", "properties": ["tabId": tabId, "ref": ref, "dx": ["type": "number"], "dy": ["type": "number"]]]
        ),
        AIToolDefinition(
            name: "select_option",
            description: "Elige una opción de una lista (select) por su texto o su valor.",
            parameters: ["type": "object", "properties": ["tabId": tabId, "ref": ref, "opcion": ["type": "string"]], "required": ["ref", "opcion"]]
        ),
        AIToolDefinition(
            name: "handle_dialog",
            description: "Contesta el diálogo de la página (alert, confirm o prompt) que esté esperando: aceptar true/false, y texto para un prompt. snapshot avisa cuando hay uno.",
            parameters: ["type": "object", "properties": ["tabId": tabId, "aceptar": ["type": "boolean"], "texto": ["type": "string"]], "required": ["aceptar"]]
        ),
        AIToolDefinition(
            name: "run_js",
            description: "Corre JavaScript en una pestaña como cuerpo de función async (usa return y await) y devuelve el resultado en JSON. mundo: \"pagina\" (por defecto; ve las variables de la página) o \"aislado\".",
            parameters: ["type": "object", "properties": ["tabId": tabId, "codigo": ["type": "string"], "mundo": ["type": "string", "enum": ["pagina", "aislado"]]], "required": ["codigo"]]
        ),
        AIToolDefinition(
            name: "screenshot_tab",
            description: "Captura de cómo se ve la pestaña (imagen JPEG). Úsala cuando importa lo visual: diseño, imágenes, gráficas, dónde está algo. Para leer texto es mejor read_page.",
            parameters: ["type": "object", "properties": ["tabId": tabId, "maxWidth": ["type": "integer", "description": "Ancho máximo en pixeles (por defecto 1200)."]]]
        ),
        AIToolDefinition(
            name: "read_page",
            description: "Lee el contenido principal de la página en markdown, sin menús ni anuncios (Defuddle), con título, autor y fecha si los hay. Para leer; para actuar usa snapshot.",
            parameters: ["type": "object", "properties": ["tabId": tabId, "max": ["type": "integer", "description": "Máximo de caracteres (por defecto 40000)."]]]
        ),
        AIToolDefinition(
            name: "close_tab",
            description: "Cierra una pestaña por su id. Úsala para no dejarle al usuario las pestañas que abriste tú.",
            parameters: ["type": "object", "properties": ["tabId": tabId], "required": ["tabId"]]
        ),
        AIToolDefinition(
            name: "list_tabs",
            description: "Todas las pestañas de todas las ventanas con su id, título, dirección, si están a la vista y si están cargadas.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        ),
        AIToolDefinition(
            name: "open_tab",
            description: "Abre una dirección en una pestaña nueva y devuelve su id. Por defecto en segundo plano, para no quitarle al usuario la pestaña que está viendo; al_frente: true para mostrarla.",
            parameters: ["type": "object", "properties": ["url": ["type": "string"], "al_frente": ["type": "boolean"]], "required": ["url"]]
        ),
        AIToolDefinition(
            name: "navigate_tab",
            description: "Lleva una pestaña a una dirección (o búsqueda) y espera a que cargue.",
            parameters: ["type": "object", "properties": ["tabId": tabId, "url": ["type": "string"]], "required": ["url"]]
        ),
    ]

    /// Las del chat viejo que estas reemplazan; se esconden del MCP para que el agente no dude.
    static let reemplazadas: Set<String> = ["clickElement", "getInteractiveElements"]

    // MARK: - Despacho

    /// nil si la herramienta no es de este archivo.
    static func call(_ name: String, _ args: [String: Any], browserManager bm: BrowserManager) async -> [String: Any]? {
        guard tools.contains(where: { $0.name == name }) else { return nil }
        do {
            switch name {
            case "list_tabs": return texto(listarPestañas(bm))
            case "open_tab": return texto(try await abrirPestaña(args, bm))
            default: break
            }
            let destino = try resolver(args, bm)
            // Con un diálogo abierto el JavaScript de la página está detenido: cualquier llamada a
            // la página (incluso instalar el script) se quedaría esperando al propio agente.
            if name == "handle_dialog" {
                let aceptar = args["aceptar"] as? Bool ?? true
                guard KurthDialogs.responder(destino.webView, aceptar: aceptar, texto: args["texto"] as? String) else {
                    return texto("No hay ningún diálogo esperando en esa pestaña.", error: true)
                }
                return texto("Diálogo \(aceptar ? "aceptado" : "cancelado").")
            }
            if KurthDialogs.pendiente(destino.webView) != nil {
                return texto(avisoDeDialogo(destino) + "Contéstalo antes de seguir.", error: true)
            }
            try await instalar(en: destino.webView)
            switch name {
            case "snapshot":
                let max = (args["max"] as? NSNumber)?.intValue ?? 400
                let foto = try await js(destino.webView, "return window.__kurth.snapshot(max)", ["max": max]) as? String ?? ""
                return texto(avisoDeDialogo(destino) + foto + modo(destino))
            case "click": return texto(try await click(args, destino))
            case "type_text": return texto(try await escribir(args, destino))
            case "press_key": return texto(try await tecla(args, destino))
            case "hover": return texto(try await hover(args, destino))
            case "scroll":
                let dy = (args["dy"] as? NSNumber)?.doubleValue ?? 600
                let dx = (args["dx"] as? NSNumber)?.doubleValue ?? 0
                let y = try await js(destino.webView, "return window.__kurth.scroll(ref, dx, dy)",
                                     ["ref": (args["ref"] as? String) ?? NSNull(), "dx": dx, "dy": dy])
                return texto("Desplazado. Scroll de la página: \(y ?? "?") px.")
            case "select_option":
                let elegido = try await js(destino.webView, "return window.__kurth.select(ref, opcion)",
                                           ["ref": try requerido(args, "ref"), "opcion": try requerido(args, "opcion")])
                return texto("Elegida: \(elegido ?? "?").")
            case "run_js":
                let mundoJS = (args["mundo"] as? String) == "aislado" ? mundo : WKContentWorld.page
                let codigo = try requerido(args, "codigo")
                let valor = try await carrera(destino) {
                    try await destino.webView.callAsyncJavaScript(codigo, arguments: [:], in: nil, contentWorld: mundoJS)
                }
                if let aviso = valor as? DialogoAbierto { return texto(aviso.texto) }
                if let v = valor, JSONSerialization.isValidJSONObject([v]),
                   let data = try? JSONSerialization.data(withJSONObject: [v], options: [.fragmentsAllowed]) {
                    return texto(String(String(decoding: data, as: UTF8.self).dropFirst().dropLast()))
                }
                return texto(valor.map { String(describing: $0) } ?? "undefined")
            case "screenshot_tab":
                let maxWidth = (args["maxWidth"] as? NSNumber)?.doubleValue ?? 1200
                let config = WKSnapshotConfiguration()
                let escala = destino.webView.window?.backingScaleFactor ?? 2
                config.snapshotWidth = NSNumber(value: min(destino.webView.bounds.width, maxWidth / escala))
                let imagen = try await destino.webView.takeSnapshot(configuration: config)
                guard let tiff = imagen.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
                    return texto("No pude codificar la captura.", error: true)
                }
                return ["content": [["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]]]
            case "read_page":
                let max = (args["max"] as? NSNumber)?.intValue ?? 40_000
                return texto(try await leer(destino.webView, url: destino.session.url, max: max))
            case "close_tab":
                bm.tabs.close(destino.itemID)
                return texto("Pestaña cerrada.")
            case "navigate_tab":
                destino.session.navigate(to: try requerido(args, "url"))
                await esperarCarga(destino.session)
                return texto("Cargada: \(destino.session.title) — \(destino.session.url.absoluteString)")
            default:
                return nil
            }
        } catch {
            return texto(error.localizedDescription, error: true)
        }
    }

    // MARK: - Pestañas

    struct Destino {
        let itemID: UUID
        let session: PageSession
        let webView: WKWebView
        /// Hay ventana y la pestaña es la que esa ventana muestra: se pueden mandar eventos nativos.
        let aLaVista: Bool
    }

    private static func resolver(_ args: [String: Any], _ bm: BrowserManager) throws -> Destino {
        let registro = bm.windowRegistry
        let itemID: UUID
        if let texto = args["tabId"] as? String, !texto.isEmpty {
            guard let id = UUID(uuidString: texto) else { throw KurthCopilotError("tabId no válido: \(texto). Usa list_tabs.") }
            itemID = id
        } else {
            guard let ventana = registro?.activeWindow ?? registro?.windows.values.first,
                  let id = ventana.selectedItemID else { throw KurthCopilotError("No hay pestaña activa. Usa list_tabs u open_tab.") }
            itemID = id
        }
        guard let session = bm.tabs.ensureSession(for: itemID) else { throw KurthCopilotError("No encontré la pestaña \(itemID). Usa list_tabs.") }
        let ventanas = registro.map { Array($0.windows.values) } ?? []
        let ventana = ventanas.first { $0.selectedItemID == itemID }
        let webView = ventana.flatMap { bm.getWebView(for: itemID, in: $0.id) } ?? despertar(session)
        guard let webView else { throw KurthCopilotError("No pude cargar la pestaña \(itemID).") }
        KurthDialogs.marcarDelAgente(webView)
        return Destino(itemID: itemID, session: session, webView: webView,
                       aLaVista: ventana != nil && webView.window != nil && !webView.isHiddenOrHasHiddenAncestor)
    }

    /// Una pestaña sin ventana (la del agente en segundo plano, o una dormida) no tiene vista web:
    /// Nook la crea al mostrarla. Aquí se crea sin mostrarla y con tamaño de ventana normal; con
    /// 0×0 la página se acomodaría en cero pixeles y la foto saldría vacía.
    private static func despertar(_ session: PageSession) -> WKWebView? {
        session.loadWebViewIfNeeded()
        guard let webView = session.webView else { return nil }
        if webView.window == nil, webView.frame.width < 100 {
            webView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        }
        return webView
    }

    private static func listarPestañas(_ bm: BrowserManager) -> String {
        guard let registro = bm.windowRegistry else { return "No hay ventanas." }
        var filas: [[String: Any]] = []
        for (n, ventana) in registro.windows.values.enumerated() {
            for id in bm.tabs.displayOrder(in: ventana) {
                let session = bm.tabs.session(for: id)
                filas.append([
                    "tabId": id.uuidString,
                    "ventana": n + 1,
                    "titulo": session?.title ?? "",
                    "url": (session?.url ?? bm.tabs.item(id)?.url)?.absoluteString ?? "",
                    "aLaVista": ventana.selectedItemID == id,
                    "cargada": session?.webView != nil,
                    "activa": ventana.id == registro.activeWindowId && ventana.selectedItemID == id,
                ])
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: filas, options: [.prettyPrinted, .sortedKeys]) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func abrirPestaña(_ args: [String: Any], _ bm: BrowserManager) async throws -> String {
        let entrada = try requerido(args, "url")
        guard let ventana = bm.windowRegistry?.activeWindow ?? bm.windowRegistry?.windows.values.first else {
            throw KurthCopilotError("No hay ventana donde abrirla.")
        }
        let plantilla = bm.nookSettings?.resolvedSearchEngineTemplate ?? SearchProvider.google.queryTemplate
        guard let url = URL(string: normalizeURL(entrada, queryTemplate: plantilla)) else { throw KurthCopilotError("Dirección no válida: \(entrada)") }
        let alFrente = args["al_frente"] as? Bool ?? false
        guard let id = bm.tabs.open(url: url, in: ventana, placement: alFrente ? .newTab : .background) else {
            throw KurthCopilotError("Nook no abrió la pestaña.")
        }
        if let session = bm.tabs.ensureSession(for: id), alFrente || despertar(session) != nil {
            await esperarCarga(session)
        }
        let cargada = bm.tabs.session(for: id)?.webView != nil
        return "tabId: \(id.uuidString)\nAbierta \(alFrente ? "al frente" : "en segundo plano")\(cargada ? "" : " (todavía sin cargar)"): \(url.absoluteString)"
    }

    private static func esperarCarga(_ session: PageSession, segundos: Double = 20) async {
        let limite = Date().addingTimeInterval(segundos)
        try? await Task.sleep(for: .milliseconds(300))
        while session.isLoading, Date() < limite { try? await Task.sleep(for: .milliseconds(200)) }
    }

    // MARK: - Acciones

    private static func click(_ args: [String: Any], _ d: Destino) async throws -> String {
        let ref = try requerido(args, "ref")
        let doble = args["doble"] as? Bool ?? false
        guard d.aLaVista else {
            let objetivo = try await carrera(d) { try await js(d.webView, "return window.__kurth.clickJS(ref)", ["ref": ref]) }
            if let aviso = objetivo as? DialogoAbierto { return "Click por JavaScript.\n" + aviso.texto }
            return "Click por JavaScript en \(objetivo ?? ref) (la pestaña no está a la vista)." + trasAccion(d)
        }
        let info = try await js(d.webView, "return window.__kurth.prepare(ref)", ["ref": ref]) as? [String: Any] ?? [:]
        let x = (info["x"] as? NSNumber)?.doubleValue ?? 0
        let y = (info["y"] as? NSNumber)?.doubleValue ?? 0
        await clickNativo(d.webView, x: x, y: y, veces: doble ? 2 : 1)
        try? await Task.sleep(for: .milliseconds(150))
        let sonda = try? await carrera(d) { try await js(d.webView, "return window.__kurth.lastClick()") }
        if let aviso = sonda as? DialogoAbierto { return "Click nativo.\n" + aviso.texto }
        let llegada = sonda as? [String: Any]
        let objetivo = info["target"] as? String ?? ref
        var nota = ""
        if let tapado = info["covered"] as? String { nota = " Ojo: en ese punto había otro elemento encima (\(tapado))." }
        // Si hubo navegación, la sonda ya no existe y no llega nada: eso también cuenta como éxito.
        if let llegada, llegada["trusted"] as? Bool == true {
            return "Click nativo en \(objetivo).\(nota)" + trasAccion(d)
        }
        if llegada == nil, d.session.isLoading || d.webView.url?.absoluteString != d.session.url.absoluteString {
            return "Click nativo en \(objetivo); la página empezó a navegar." + trasAccion(d)
        }
        let repetido = try await carrera(d) { try await js(d.webView, "return window.__kurth.clickJS(ref)", ["ref": ref]) }
        if let aviso = repetido as? DialogoAbierto { return "El click nativo no llegó; repetido por JavaScript.\n" + aviso.texto }
        return "El click nativo no llegó; repetido por JavaScript en \(objetivo).\(nota)" + trasAccion(d)
    }

    private static func escribir(_ args: [String: Any], _ d: Destino) async throws -> String {
        let ref = try requerido(args, "ref")
        let texto = try requerido(args, "texto")
        let limpiar = args["limpiar"] as? Bool ?? false
        let enviar = args["enviar"] as? Bool ?? false
        var modo = "javascript"
        var valor = ""
        if d.aLaVista {
            // Enfoca con un click humano y escribe tecla por tecla, como una persona.
            let info = try await js(d.webView, "return window.__kurth.prepare(ref)", ["ref": ref]) as? [String: Any] ?? [:]
            await clickNativo(d.webView, x: (info["x"] as? NSNumber)?.doubleValue ?? 0, y: (info["y"] as? NSNumber)?.doubleValue ?? 0, veces: 1)
            _ = try await js(d.webView, "return window.__kurth.focus(ref, limpiar)", ["ref": ref, "limpiar": limpiar])
            // InsertText de WebKit: dispara beforeinput/input de persona (isTrusted) sin depender de
            // quién tenga el foco en la ventana; con el texto seleccionado (limpiar), lo reemplaza.
            // La técnica es la de Bun.WebView (tests en oven-sh/bun webview.test.ts:722-749).
            if await comandoDeEdicion(d.webView, "InsertText", argumento: texto) == false {
                d.webView.window?.makeFirstResponder(d.webView)
                for caracter in texto {
                    let s = String(caracter)
                    pulsar(d.webView, KurthTecla(caracteres: s, codigo: KurthTecla.codigo(de: s), mods: []))
                }
            }
            try? await Task.sleep(for: .milliseconds(120))
            valor = (try? await js(d.webView, "return window.__kurth.valueOf(ref)", ["ref": ref])) as? String ?? ""
            if valor.contains(texto) { modo = "nativo" }
        }
        if modo != "nativo" {
            valor = try await js(d.webView, "return window.__kurth.typeJS(ref, texto, limpiar)",
                                 ["ref": ref, "texto": texto, "limpiar": limpiar]) as? String ?? ""
        }
        var resultado = "Escrito (\(modo)). Valor del campo: \(valor.count > 120 ? String(valor.prefix(120)) + "…" : valor)"
        if enviar {
            if d.aLaVista, modo == "nativo" { pulsar(d.webView, KurthTecla.parse("Enter", [])!) }
            else { _ = try await carrera(d) { try await js(d.webView, "return window.__kurth.keyJS('Enter', {})") } }
            try? await Task.sleep(for: .milliseconds(300))
            resultado += "\nEnter presionado."
        }
        return resultado + trasAccion(d)
    }

    private static func tecla(_ args: [String: Any], _ d: Destino) async throws -> String {
        let nombre = try requerido(args, "tecla")
        let mods = (args["modificadores"] as? [String]) ?? []
        guard let t = KurthTecla.parse(nombre, mods) else { throw KurthCopilotError("No conozco la tecla \(nombre).") }
        if d.aLaVista {
            d.webView.window?.makeFirstResponder(d.webView)
            pulsar(d.webView, t)
            try? await Task.sleep(for: .milliseconds(150))
            return "Tecla \(nombre) (nativa)." + trasAccion(d)
        }
        let modsJS: [String: Bool] = ["metaKey": mods.contains("cmd"), "shiftKey": mods.contains("shift"),
                                      "altKey": mods.contains("alt"), "ctrlKey": mods.contains("ctrl")]
        _ = try await carrera(d) { try await js(d.webView, "return window.__kurth.keyJS(tecla, mods)", ["tecla": nombre, "mods": modsJS]) }
        return "Tecla \(nombre) por JavaScript (la pestaña no está a la vista; solo la oyen los keydown de la página)." + trasAccion(d)
    }

    private static func hover(_ args: [String: Any], _ d: Destino) async throws -> String {
        let ref = try requerido(args, "ref")
        if d.aLaVista {
            let info = try await js(d.webView, "return window.__kurth.prepare(ref)", ["ref": ref]) as? [String: Any] ?? [:]
            let p = punto(d.webView, x: (info["x"] as? NSNumber)?.doubleValue ?? 0, y: (info["y"] as? NSNumber)?.doubleValue ?? 0)
            // WKWebView no reenvía mouseMoved; safaridriver usa _simulateMouseMove: (macOS 13).
            let simular = NSSelectorFromString("_simulateMouseMove:")
            if let e = raton(.mouseMoved, en: p, d.webView) {
                if d.webView.responds(to: simular) { d.webView.perform(simular, with: e) } else { d.webView.mouseMoved(with: e) }
            }
            try? await Task.sleep(for: .milliseconds(200))
            return "Mouse encima de \(info["target"] as? String ?? ref) (nativo)." + trasAccion(d)
        }
        let objetivo = try await js(d.webView, "return window.__kurth.hoverJS(ref)", ["ref": ref])
        return "Mouse encima de \(objetivo ?? ref) (JavaScript)." + trasAccion(d)
    }

    private static func trasAccion(_ d: Destino) -> String {
        avisoDeDialogo(d).isEmpty ? "" : "\n" + avisoDeDialogo(d)
    }

    private static func avisoDeDialogo(_ d: Destino) -> String {
        guard let p = KurthDialogs.pendiente(d.webView) else { return "" }
        return "⚠️ Diálogo esperando (\(p.tipo)): «\(p.mensaje)» — contéstalo con handle_dialog.\n\n"
    }

    private static func modo(_ d: Destino) -> String {
        d.aLaVista ? "" : "\n\n(Pestaña sin ventana: las acciones irán por JavaScript.)"
    }

    // MARK: - Eventos nativos

    /// De coordenadas del viewport de la página (px CSS) a coordenadas de ventana.
    private static func punto(_ webView: WKWebView, x: Double, y: Double) -> NSPoint {
        let escala = webView.pageZoom * webView.magnification
        let margen = webView.obscuredContentInsets
        let vx = margen.left + x * escala
        let vy = margen.top + y * escala
        let enVista = webView.isFlipped ? NSPoint(x: vx, y: vy) : NSPoint(x: vx, y: webView.bounds.height - vy)
        return webView.convert(enVista, to: nil)
    }

    private static func raton(_ tipo: NSEvent.EventType, en p: NSPoint, _ webView: WKWebView, veces: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: tipo, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: webView.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                           clickCount: veces, pressure: tipo == .leftMouseDown ? 1 : 0)
    }

    private static func clickNativo(_ webView: WKWebView, x: Double, y: Double, veces: Int) async {
        let p = punto(webView, x: x, y: y)
        if let mover = raton(.mouseMoved, en: p, webView) { webView.mouseMoved(with: mover) }
        for n in 1...veces {
            if let abajo = raton(.leftMouseDown, en: p, webView, veces: n) { webView.mouseDown(with: abajo) }
            try? await Task.sleep(for: .milliseconds(40))
            if let arriba = raton(.leftMouseUp, en: p, webView, veces: n) { webView.mouseUp(with: arriba) }
        }
    }

    /// `-[WKWebView _executeEditCommand:argument:completion:]` (SPI, macOS 10.13.4). nil si no existe.
    private static func comandoDeEdicion(_ webView: WKWebView, _ comando: String, argumento: String?) async -> Bool? {
        let sel = NSSelectorFromString("_executeEditCommand:argument:completion:")
        guard webView.responds(to: sel), let imp = webView.method(for: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, NSString, NSString?, @escaping @convention(block) (Bool) -> Void) -> Void
        let llamar = unsafeBitCast(imp, to: Fn.self)
        return await withCheckedContinuation { cont in
            llamar(webView, sel, comando as NSString, argumento as NSString?) { ok in cont.resume(returning: ok) }
        }
    }

    private static func pulsar(_ webView: WKWebView, _ t: KurthTecla) {
        for tipo in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: tipo, location: .zero, modifierFlags: t.mods,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: webView.window?.windowNumber ?? 0, context: nil,
                                           characters: t.caracteres, charactersIgnoringModifiers: t.caracteres,
                                           isARepeat: false, keyCode: t.codigo) else { continue }
            if tipo == .keyDown { webView.keyDown(with: e) } else { webView.keyUp(with: e) }
        }
    }

    // MARK: - Leer (Defuddle)

    /// Defuddle 0.19.4 (MIT, kepano/defuddle), build "full" porque el markdown lo necesita. Son
    /// 748 KB: se inyecta en el mundo aislado solo cuando se pide leer, no en cada página.
    private static let defuddle: String = {
        guard let ruta = Bundle.main.path(forResource: "Defuddle.full", ofType: "js"),
              let js = try? String(contentsOfFile: ruta, encoding: .utf8) else { return "" }
        return js
    }()

    /// El contenido de una pestaña para mandarlo junto con la pregunta del panel (KurthAgentChat):
    /// así el agente contesta sin usar herramientas. Medido el 24 sep: con el contenido en el
    /// mensaje y esfuerzo bajo, 5–7 s; buscando la herramienta y leyendo, 14–17 s. nil si falla.
    static func contenidoParaAgente(_ webView: WKWebView, url: URL, max: Int = 12_000) async -> String? {
        guard KurthDialogs.pendiente(webView) == nil else { return nil }
        return try? await leer(webView, url: url, max: max)
    }

    private static func leer(_ webView: WKWebView, url: URL, max: Int) async throws -> String {
        guard !defuddle.isEmpty else { throw KurthCopilotError("Falta Defuddle en la app.") }
        try await instalar(en: webView)
        let hay = try await js(webView, "return typeof self.Defuddle === 'function'") as? Bool ?? false
        if !hay { _ = try await webView.callAsyncJavaScript(defuddle + "\nreturn true", arguments: [:], in: nil, contentWorld: mundo) }
        let r = try await js(webView, """
            const r = new self.Defuddle(document, { markdown: true, url: location.href }).parse();
            return { titulo: r.title || document.title, autor: r.author || '', fecha: r.published || '',
                     sitio: r.site || '', palabras: r.wordCount || 0, contenido: r.content || '' };
            """) as? [String: Any] ?? [:]
        var contenido = r["contenido"] as? String ?? ""
        let total = contenido.count
        if total > max { contenido = String(contenido.prefix(max)) + "\n\n… (cortado en \(max) de \(total) caracteres; pide más con max)" }
        let meta = [("Título", r["titulo"]), ("Autor", r["autor"]), ("Fecha", r["fecha"]), ("Sitio", r["sitio"])]
            .compactMap { clave, valor in (valor as? String).flatMap { $0.isEmpty ? nil : "\(clave): \($0)" } }
            .joined(separator: "\n")
        return meta + "\nDirección: \(url.absoluteString)\nPalabras: \(r["palabras"] ?? 0)\n\n" + contenido
    }

    // MARK: - Diálogos a media acción

    /// Un alert/confirm/prompt detiene el JavaScript de la página hasta que alguien contesta. Si
    /// una acción lo abre, esperar a que el JS termine sería esperar al propio agente: se trabaría.
    /// Esto espera lo primero que pase — que termine, o que aparezca un diálogo — y en el segundo
    /// caso devuelve DialogoAbierto; lo que quedó corriendo termina solo cuando se conteste.
    struct DialogoAbierto { let texto: String }

    @MainActor private final class Caja { var listo = false; var valor: Any?; var error: Error? }

    private static func carrera(_ d: Destino, segundos: Double = 20, _ trabajo: @escaping @MainActor () async throws -> Any?) async throws -> Any? {
        let caja = Caja()
        Task { @MainActor in
            do { caja.valor = try await trabajo() } catch { caja.error = error }
            caja.listo = true
        }
        let limite = Date().addingTimeInterval(segundos)
        while !caja.listo {
            if KurthDialogs.pendiente(d.webView) != nil { return DialogoAbierto(texto: avisoDeDialogo(d).trimmingCharacters(in: .whitespacesAndNewlines)) }
            if Date() > limite { throw KurthCopilotError("La página no respondió en \(Int(segundos)) s.") }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let error = caja.error { throw error }
        return caja.valor
    }

    // MARK: - JavaScript

    static let mundo = WKContentWorld.world(name: "KurthCopilot")

    private static let fuente: String = {
        guard let ruta = Bundle.main.path(forResource: "KurthCopilot", ofType: "js"),
              let js = try? String(contentsOfFile: ruta, encoding: .utf8) else { return "" }
        return js
    }()

    private static func instalar(en webView: WKWebView) async throws {
        guard !fuente.isEmpty else { throw KurthCopilotError("Falta KurthCopilot.js en la app.") }
        _ = try await webView.callAsyncJavaScript(fuente + "\nreturn true", arguments: [:], in: nil, contentWorld: mundo)
    }

    @discardableResult
    private static func js(_ webView: WKWebView, _ codigo: String, _ args: [String: Any] = [:]) async throws -> Any? {
        do {
            return try await webView.callAsyncJavaScript(codigo, arguments: args, in: nil, contentWorld: mundo)
        } catch {
            // El mensaje útil de un throw en el JS viene en userInfo.
            let ns = error as NSError
            let mensaje = ns.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw KurthCopilotError(mensaje)
        }
    }

    // MARK: - Utilidades

    private static func requerido(_ args: [String: Any], _ clave: String) throws -> String {
        guard let v = args[clave] as? String, !v.isEmpty else { throw KurthCopilotError("Falta \(clave).") }
        return v
    }

    private static func texto(_ s: String, error: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": s]], "isError": error]
    }
}

struct KurthCopilotError: LocalizedError {
    let errorDescription: String?
    init(_ mensaje: String) { errorDescription = mensaje }
}

/// Una tecla lista para mandarse como NSEvent: los caracteres que produce y su código físico.
struct KurthTecla {
    let caracteres: String
    let codigo: UInt16
    let mods: NSEvent.ModifierFlags

    init(caracteres: String, codigo: UInt16, mods: NSEvent.ModifierFlags) {
        self.caracteres = caracteres
        self.codigo = codigo
        self.mods = mods
    }

    private static func funcion(_ c: Int) -> String { String(Character(UnicodeScalar(UInt32(c))!)) }

    static func parse(_ nombre: String, _ modificadores: [String]) -> KurthTecla? {
        var mods: NSEvent.ModifierFlags = []
        for m in modificadores.map({ $0.lowercased() }) {
            switch m {
            case "cmd", "command", "meta": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "alt", "option": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: break
            }
        }
        let especiales: [String: (String, UInt16)] = [
            "enter": ("\r", 36), "return": ("\r", 36), "tab": ("\t", 48), "space": (" ", 49),
            "backspace": ("\u{7f}", 51), "escape": ("\u{1b}", 53), "esc": ("\u{1b}", 53),
            "delete": (funcion(NSDeleteFunctionKey), 117),
            "arrowleft": (funcion(NSLeftArrowFunctionKey), 123), "arrowright": (funcion(NSRightArrowFunctionKey), 124),
            "arrowdown": (funcion(NSDownArrowFunctionKey), 125), "arrowup": (funcion(NSUpArrowFunctionKey), 126),
            "home": (funcion(NSHomeFunctionKey), 115), "end": (funcion(NSEndFunctionKey), 119),
            "pageup": (funcion(NSPageUpFunctionKey), 116), "pagedown": (funcion(NSPageDownFunctionKey), 121),
        ]
        if let (c, k) = especiales[nombre.lowercased()] {
            if [123, 124, 125, 126, 115, 119, 116, 121, 117].contains(k) { mods.insert(.function) }
            return KurthTecla(caracteres: c, codigo: k, mods: mods)
        }
        guard nombre.count == 1 else { return nil }
        return KurthTecla(caracteres: nombre, codigo: codigo(de: nombre), mods: mods)
    }

    /// Código físico de las letras y números del teclado US. Para lo demás 0: el texto va en los
    /// caracteres, que es lo que usan las páginas (event.key).
    static func codigo(de s: String) -> UInt16 {
        let mapa: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
            "n": 45, "m": 46, " ": 49,
        ]
        guard let c = s.lowercased().first else { return 0 }
        return mapa[c] ?? 0
    }
}
