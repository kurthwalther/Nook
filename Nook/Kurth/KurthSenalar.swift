// Licensed under GPL-3.0. See LICENSE.
//
//  KurthSenalar.swift
//  Nook (rama kurth)
//
//  "Señalar": Kurth y el agente se apuntan cosas en la página (diseño en kurth/diseño-señalar.md).
//   - Modo caja (⌘⇧M o el botón del chat): Kurth arrastra un rectángulo sobre la página. Sale una
//     referencia con el recorte de captura, el texto de adentro, los elementos (@eN) y un ancla
//     para volver a encontrarla; va como chip en la caja de texto y viaja con el mensaje.
//   - Selección de texto: al enfocar la caja de texto, si hay texto seleccionado entra como chip.
//   - Marcas del agente (herramientas highlight/point_to de KurthCopilot) y chips 📍 en el chat.
//   - Persistencia: las marcas se guardan por dirección y la página las pide al cargar
//     (mensaje "pedirMarcas" de KurthCopilot.js); se vuelven a anclar por contenedor y texto.
//

import AppKit
import SwiftUI
import WebKit
import NookBlocker
import NookWeb

@MainActor
@Observable
final class KurthSenalar {
    static let shared = KurthSenalar()

    struct Referencia: Identifiable {
        let id: String
        let numero: Int
        let tipo: String            // "caja" o "texto"
        let tabId: UUID
        let url: String
        let titulo: String
        let texto: String
        let elementos: [String]
        let imagenes: [String]
        let recorte: Data?          // JPEG

        var resumen: String {
            let base = texto.isEmpty ? (elementos.first ?? "zona de la página") : "«\(texto)»"
            return base.count > 42 ? String(base.prefix(41)) + "…" : base
        }
    }

    /// Ventana en modo caja (el cursor es una cruz y arrastrar dibuja un rectángulo).
    var modoCaja: UUID?
    private(set) var referencias: [Referencia] = []
    private var siguienteNumero = 1
    /// id de marca → pestaña, para que un chip 📍 del chat sepa a dónde ir.
    private var pestañaDeMarca: [String: UUID] = [:]
    private var monitorEsc: Any?

    private init() { cargar() }

    // MARK: - Modo caja

    func alternarModoCaja(en ventana: BrowserWindowState) {
        if modoCaja == ventana.id { salirDeModoCaja() } else { entrarAModoCaja(ventana.id) }
    }

    private func entrarAModoCaja(_ id: UUID) {
        modoCaja = id
        monitorEsc = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] evento in
            guard evento.keyCode == 53 else { return evento }
            MainActor.assumeIsolated { self?.salirDeModoCaja() }
            return nil
        }
    }

    func salirDeModoCaja() {
        modoCaja = nil
        if let m = monitorEsc { NSEvent.removeMonitor(m) }
        monitorEsc = nil
    }

    /// El rectángulo que dibujó Kurth, en coordenadas globales de SwiftUI (las de la vista raíz
    /// de la ventana). Se convierte a la vista web, luego al viewport de la página.
    func terminarCaja(_ global: CGRect, ventana: BrowserWindowState, bm: BrowserManager) async {
        salirDeModoCaja()
        guard global.width > 6, global.height > 6,
              let sesion = bm.tabs.selectedSession(in: ventana),
              let webView = bm.getWebView(for: sesion.itemID, in: ventana.id) ?? sesion.webView,
              let raiz = webView.window?.contentView else { return }
        let a = webView.convert(NSPoint(x: global.minX, y: global.minY), from: raiz)
        let b = webView.convert(NSPoint(x: global.maxX, y: global.maxY), from: raiz)
        let enVista = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .intersection(webView.bounds)
        guard !enVista.isEmpty else { return }
        let css = Self.aViewport(enVista, webView)
        let id = "k" + UUID().uuidString.prefix(6).lowercased()
        let numero = siguienteNumero
        guard let datos = try? await KurthCopilot.enMarcas(webView, """
            const c = window.__kurth.marcas.contenido({x, y, w, h});
            window.__kurth.marcas.caja({id, autor: 'tu', x, y, w, h, numero});
            return c;
            """, ["x": css.minX, "y": css.minY, "w": css.width, "h": css.height, "id": id, "numero": numero]) as? [String: Any] else { return }
        siguienteNumero += 1
        let recorte = await Self.recorte(webView, enVista)
        let ref = Referencia(id: id, numero: numero, tipo: "caja", tabId: sesion.itemID, url: sesion.url.absoluteString,
                             titulo: sesion.title, texto: datos["texto"] as? String ?? "",
                             elementos: datos["elementos"] as? [String] ?? [], imagenes: datos["imagenes"] as? [String] ?? [],
                             recorte: recorte)
        referencias.append(ref)
        pestañaDeMarca[id] = sesion.itemID
        guardarMarca(url: sesion.url, [
            "id": id, "autor": "tu", "tipo": "caja", "numero": numero,
            "ancla": datos["ancla"] ?? [:], "nota": "",
        ])
    }

    // MARK: - Selección de texto

    /// Si la pestaña tiene texto seleccionado, entra como referencia (y se queda resaltado en azul
    /// aunque la selección se pierda al pasar al chat).
    func adjuntarSeleccion(ventana: BrowserWindowState, bm: BrowserManager) async {
        guard let sesion = bm.tabs.selectedSession(in: ventana),
              let webView = bm.getWebView(for: sesion.itemID, in: ventana.id) ?? sesion.webView,
              let sel = try? await KurthCopilot.enMarcas(webView, "return window.__kurth.marcas.seleccion()") as? [String: Any],
              let texto = sel["texto"] as? String, !texto.isEmpty,
              !referencias.contains(where: { $0.tabId == sesion.itemID && $0.texto == texto }) else { return }
        let id = "k" + UUID().uuidString.prefix(6).lowercased()
        let numero = siguienteNumero
        siguienteNumero += 1
        _ = try? await KurthCopilot.enMarcas(webView, "return window.__kurth.marcas.texto({id, autor: 'tu', texto, prefijo, sufijo, numero})",
                                           ["id": id, "texto": texto, "prefijo": sel["prefijo"] ?? "", "sufijo": sel["sufijo"] ?? "", "numero": numero])
        referencias.append(Referencia(id: id, numero: numero, tipo: "texto", tabId: sesion.itemID, url: sesion.url.absoluteString,
                                      titulo: sesion.title, texto: texto, elementos: [], imagenes: [], recorte: nil))
        pestañaDeMarca[id] = sesion.itemID
        guardarMarca(url: sesion.url, ["id": id, "autor": "tu", "tipo": "texto", "numero": numero,
                                       "cita": texto, "prefijo": sel["prefijo"] ?? "", "sufijo": sel["sufijo"] ?? "", "nota": ""])
    }

    func quitarReferencia(_ ref: Referencia, bm: BrowserManager) {
        referencias.removeAll { $0.id == ref.id }
        olvidarMarca(ref.id)
        if let webView = webView(de: ref.tabId, bm: bm) {
            Task { _ = try? await KurthCopilot.enMarcas(webView, "return window.__kurth.marcas.quitar(id)", ["id": ref.id]) }
        }
    }

    /// Lo que va con el mensaje. Las marcas se quedan en la página (y guardadas).
    func tomarReferencias() -> [Referencia] {
        defer { referencias.removeAll() }
        return referencias
    }

    func reiniciarNumeros() { siguienteNumero = 1 }

    /// El texto que describe una referencia para el agente.
    static func descripcion(_ r: Referencia) -> String {
        var s = "[Señalado \(r.numero)] Kurth señaló "
        s += r.tipo == "texto" ? "este texto" : "esta zona (va el recorte de captura)"
        s += " en «\(r.titulo)» (\(r.url)):"
        if !r.texto.isEmpty { s += "\nTexto: «\(r.texto)»" }
        if !r.elementos.isEmpty { s += "\nElementos adentro:\n" + r.elementos.joined(separator: "\n") }
        if !r.imagenes.isEmpty { s += "\nImágenes: " + r.imagenes.joined(separator: " | ") }
        return s
    }

    // MARK: - Marcas del agente y chips 📍

    func registrarMarca(_ id: String, tab: UUID) { pestañaDeMarca[id] = tab }

    /// Toque en un chip 📍 (kurth-marca:ID): muestra la pestaña si hace falta y hace destellar.
    func irAMarca(_ id: String, ventana: BrowserWindowState, bm: BrowserManager) {
        guard let tab = pestañaDeMarca[id] ?? pestañaGuardada(id, bm: bm) else { return }
        if ventana.selectedItemID != tab { bm.tabs.select(tab, in: ventana) }
        Task {
            try? await Task.sleep(for: .milliseconds(ventana.selectedItemID == tab ? 0 : 500))
            guard let webView = self.webView(de: tab, bm: bm) else { return }
            _ = try? await KurthCopilot.enMarcas(webView, "return window.__kurth.marcas.destellar(id)", ["id": id])
        }
    }

    private func webView(de tab: UUID, bm: BrowserManager) -> WKWebView? {
        let ventanas = bm.windowRegistry.map { Array($0.windows.values) } ?? []
        if let v = ventanas.first(where: { $0.selectedItemID == tab }), let wv = bm.getWebView(for: tab, in: v.id) { return wv }
        return bm.tabs.session(for: tab)?.webView
    }

    private func pestañaGuardada(_ id: String, bm: BrowserManager) -> UUID? {
        guard let url = marcas.first(where: { $0.value.contains { ($0["id"] as? String) == id } })?.key else { return nil }
        let ventanas = bm.windowRegistry.map { Array($0.windows.values) } ?? []
        for v in ventanas {
            if let t = bm.tabs.displayOrder(in: v).first(where: { Self.clave(bm.tabs.session(for: $0)?.url) == url }) { return t }
        }
        return nil
    }

    // MARK: - Persistencia (marcas por dirección)

    /// dirección sin fragmento → marcas (diccionarios que KurthCopilot.js sabe restaurar).
    private var marcas: [String: [[String: Any]]] = [:]

    private static let archivo: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.gstudios.nook/Kurth/marcas.json")
    }()

    static func clave(_ url: URL?) -> String {
        guard let url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        c.fragment = nil
        return c.string ?? url.absoluteString
    }

    func marcasGuardadas(para url: URL?) -> [[String: Any]] { marcas[Self.clave(url)] ?? [] }

    func guardarMarca(url: URL, _ marca: [String: Any]) {
        marcas[Self.clave(url), default: []].append(marca)
        escribir()
    }

    func olvidarMarca(_ id: String) {
        for (k, lista) in marcas { marcas[k] = lista.filter { ($0["id"] as? String) != id } }
        marcas = marcas.filter { !$0.value.isEmpty }
        escribir()
    }

    func olvidarMarcas(url: URL?, autor: String?) {
        let k = Self.clave(url)
        marcas[k] = (marcas[k] ?? []).filter { autor != nil && ($0["autor"] as? String) != autor }
        if marcas[k]?.isEmpty == true { marcas[k] = nil }
        escribir()
    }

    private func cargar() {
        guard let datos = try? Data(contentsOf: Self.archivo),
              let obj = try? JSONSerialization.jsonObject(with: datos) as? [String: [[String: Any]]] else { return }
        marcas = obj
    }

    private func escribir() {
        guard let datos = try? JSONSerialization.data(withJSONObject: marcas, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: Self.archivo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? datos.write(to: Self.archivo, options: .atomic)
    }

    // MARK: - Instalación en cada vista web

    private static var controladores = Set<ObjectIdentifier>()
    private static let canal = Canal()

    /// El script del copiloto va en todas las páginas (mundo aislado) para que cada una pida sus
    /// marcas al cargar; el canal "kurthSenalar" recibe ese pedido. Una vez por controlador.
    static func instalar(en webView: WKWebView) {
        let controlador = webView.configuration.userContentController
        guard controladores.insert(ObjectIdentifier(controlador)).inserted else { return }
        controlador.add(canal, contentWorld: KurthCopilot.mundo, name: "kurthSenalar")
        if let fuente = KurthCopilot.fuenteDelScript {
            // "// Nook" al frente: sin el marcador de NookOwned los tweaks lo quitaban en la primera navegación.
            controlador.addUserScript(WKUserScript(source: WKUserScript.nookOwnedPrefix + " kurth: copiloto\n" + fuente, injectionTime: .atDocumentEnd,
                                                   forMainFrameOnly: true, in: KurthCopilot.mundo))
        }
    }

    private final class Canal: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive mensaje: WKScriptMessage) {
            guard let cuerpo = mensaje.body as? [String: Any], let webView = mensaje.webView else { return }
            // El encabezado fijo que el script ve pegado arriba (KurthPageState.scriptHeaderColor).
            if cuerpo["tipo"] as? String == "encabezado" {
                let rgba = (cuerpo["rgba"] as? [NSNumber])?.map { CGFloat($0.doubleValue) / 255 }
                MainActor.assumeIsolated {
                    let color = rgba.flatMap { $0.count == 4 ? NSColor(srgbRed: $0[0], green: $0[1], blue: $0[2], alpha: $0[3]) : nil }
                    KurthPageState.of(webView).setScriptHeaderColor(color)
                }
                return
            }
            guard cuerpo["tipo"] as? String == "pedirMarcas", let texto = cuerpo["url"] as? String else { return }
            MainActor.assumeIsolated {
                let lista = KurthSenalar.shared.marcasGuardadas(para: URL(string: texto))
                guard !lista.isEmpty else { return }
                Task { _ = try? await KurthCopilot.enMarcas(webView, "return window.__kurth.marcas.restaurar(lista)", ["lista": lista]) }
            }
        }
    }

    // MARK: - Geometría

    /// Rectángulo en la vista web (puntos, WKWebView es flipped) → viewport de la página (px CSS).
    static func aViewport(_ r: CGRect, _ webView: WKWebView) -> CGRect {
        let escala = max(webView.pageZoom * webView.magnification, 0.01)
        let m = webView.obscuredContentInsets
        return CGRect(x: (r.minX - m.left) / escala, y: (r.minY - m.top) / escala, width: r.width / escala, height: r.height / escala)
    }

    private static func recorte(_ webView: WKWebView, _ r: CGRect) async -> Data? {
        let config = WKSnapshotConfiguration()
        config.rect = r
        config.snapshotWidth = NSNumber(value: min(r.width, 900))
        guard let imagen = try? await webView.takeSnapshot(configuration: config),
              let tiff = imagen.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }
}
