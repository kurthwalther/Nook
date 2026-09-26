// Licensed under GPL-3.0. See LICENSE.
//
//  KurthSplit.swift
//  Nook (rama kurth)
//
//  Split útil (plan del 26 sep, punto 8). Nook ya dividía la ventana (SplitViewManager) pero la única
//  entrada era arrastrar una pestaña a unas tarjetas en medio de la página, y Kurth no dio con ella.
//  Aquí va lo que lo vuelve de uso diario:
//  1. Clic derecho en un link → "Abrir en el split": la página del link a la derecha; si ya hay
//     split, reemplaza el panel derecho (WebContextMenu.linkOpenInSplit).
//  2. Pestaña seguidora: "Seguir aquí los links" en el menú de una pestaña (KurthSplitMenu). Mientras
//     siga, cada link que se abra en el panel izquierdo se carga en el derecho en vez de navegar
//     (gancho en PageSession.decidePolicyFor). Se apaga sola al cerrar el split o cambiar el panel.
//  3. Arrastrar una pestaña (lateral o tira compacta) hasta la orilla derecha de la página abre el
//     split con ella a la derecha; una franja translúcida marca la zona (KurthSplitZonaDeOrilla).
//     La tira usa un DragGesture de SwiftUI, no una sesión de arrastre de AppKit, así que la vista
//     que recibe los arrastres de la lateral no se entera: ArrastreDeTira la alimenta con el mouse.
//  4. ⌥-clic: en una mitad del split la saca (la otra se queda con la ventana); en una fila normal
//     con split abierto la mete al panel derecho.
//  Ajustes: kurth.splitEdgeWidth (ancho de la orilla, 40 pt) y kurth.splitOptionClick.
//  MCP: kurth_split (open / close / follow / status) para probar sin mouse.
//

import AppKit
import SwiftUI
import NookDesign
import NookWeb
import NookTabsCore

@MainActor
enum KurthSplit {
    /// Ancho de la franja en la orilla derecha de la página que recibe el arrastre.
    static var anchoDeOrilla: CGFloat {
        let v = UserDefaults.standard.double(forKey: "kurth.splitEdgeWidth")
        return v > 0 ? v : 40
    }

    static var clicConOpcionActivo: Bool {
        UserDefaults.standard.object(forKey: "kurth.splitOptionClick") as? Bool ?? true
    }

    private static weak var bm: BrowserManager?

    /// Los ganchos de NookWeb y NookUI apuntan aquí (NookApp.onAppear).
    static func registrar(browserManager: BrowserManager) {
        bm = browserManager
        let gancho = KurthSplitGancho.shared
        gancho.abrirDerecha = { id, window in aLaDerecha(id, en: window) }
        gancho.clicConOpcion = { id, window in clicConOpcion(id, en: window) }
        gancho.seguirLink = { session, url in seguir(url, desde: session) }
    }

    // MARK: - Acciones

    /// Esa pestaña al panel derecho; sin split, se abre junto a la elegida.
    static func aLaDerecha(_ id: UUID, en window: BrowserWindowState) {
        bm?.splitManager.enterSplit(with: id, placeOn: .right, in: window)
    }

    /// "Abrir en el split" del menú de un link: pestaña nueva en segundo plano, hija de la que tiene
    /// el link (como "Open Link in New Tab"), y al panel derecho. Solo http(s), como openInNewTab.
    static func abrirLink(_ url: URL, desde session: PageSession?) {
        guard let bm, let session, let window = bm.tabs.window(for: session) else { return }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        guard let id = bm.tabs.open(url: url, in: window, placement: .background, from: session.itemID) else { return }
        bm.splitManager.enterSplit(with: id, placeOn: .right, in: window)
    }

    /// ⌥-clic sobre una fila. En el split: esa mitad sale y la otra se queda con toda la ventana.
    /// Fuera, con split abierto: entra al panel derecho. Sin split, o sin ⌥: false y la fila hace
    /// lo de siempre. La tecla se lee del evento del clic y del estado del teclado, por si el
    /// mouseUp llegó sin la bandera.
    static func clicConOpcion(_ id: UUID, en window: BrowserWindowState) -> Bool {
        guard clicConOpcionActivo, let bm, let split = window.split else { return false }
        let conOpcion = NSApp.currentEvent?.modifierFlags.contains(.option) == true
            || NSEvent.modifierFlags.contains(.option)
        guard conOpcion else { return false }
        let sm = bm.splitManager
        switch id {
        case split.leftItemID: sm.exitSplit(keep: .right, for: window.id)
        case split.rightItemID: sm.exitSplit(keep: .left, for: window.id)
        default: sm.enterSplit(with: id, placeOn: .right, in: window)
        }
        return true
    }

    /// Un link activado en `session`: si es el panel izquierdo de una ventana cuya derecha sigue, se
    /// carga allá. La izquierda no navega y sigue elegida, para seguir dando clics.
    static func seguir(_ url: URL, desde session: PageSession) -> Bool {
        guard let bm, let registry = bm.windowRegistry else { return false }
        let gancho = KurthSplitGancho.shared
        let ventana = registry.windows.values.first { window in
            guard let split = window.split, split.leftItemID == session.itemID else { return false }
            return gancho.sigue(split.rightItemID, en: window)
        }
        guard let derecha = ventana?.split?.rightItemID, let destino = bm.tabs.ensureSession(for: derecha) else { return false }
        destino.load(url)
        return true
    }

    // MARK: - Orilla

    /// La orilla derecha del área de la página: soltar ahí = split a la derecha. Se pregunta antes
    /// que las tarjetas, que también cubren esa franja.
    static func ladoPorOrilla(_ punto: CGPoint, en bounds: CGRect) -> SplitViewManager.Side? {
        guard bounds.contains(punto), punto.x >= bounds.maxX - anchoDeOrilla else { return nil }
        return .right
    }

    /// Arrastre de un segmento de la tira compacta sobre la página: mueve la misma vista previa que
    /// un arrastre de la lateral y, al soltar, abre el split. Uno por tira, vive en su @State.
    @MainActor
    final class ArrastreDeTira {
        private var activo = false
        private(set) var lado: SplitViewManager.Side?

        func mover(en window: BrowserWindowState) {
            guard let bm = KurthSplit.bm, let overlay = overlay(de: window), let nsWindow = overlay.window else { return }
            let punto = overlay.convert(nsWindow.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let sm = bm.splitManager
            guard overlay.bounds.contains(punto) else {
                if activo { terminar(sm, window, cancelar: true) }
                return
            }
            lado = overlay.side(atLocal: punto)
            sm.updateDragLocation(punto, for: window.id)
            if activo {
                sm.updatePreviewSide(lado, for: window.id)
            } else {
                activo = true
                sm.beginPreview(side: lado, for: window.id)
            }
        }

        /// true si el soltar cayó sobre la página (con lado o sin él): la tira no reordena.
        func soltar(_ id: UUID, en window: BrowserWindowState) -> Bool {
            guard activo, let bm = KurthSplit.bm else { lado = nil; return false }
            let sm = bm.splitManager
            let destino = lado
            terminar(sm, window, cancelar: false)
            if let destino { sm.enterSplit(with: id, placeOn: destino, in: window) }
            return true
        }

        private func terminar(_ sm: SplitViewManager, _ window: BrowserWindowState, cancelar: Bool) {
            activo = false
            lado = nil
            sm.updateDragLocation(nil, for: window.id)
            sm.endPreview(cancel: cancelar, for: window.id)
        }

        private func overlay(de window: BrowserWindowState) -> SplitDropCaptureView? {
            KurthSplit.bm?.webViewCoordinator?.compositorContainerView(for: window.id)?
                .subviews.compactMap { $0 as? SplitDropCaptureView }.first
        }
    }

    // MARK: - MCP

    static let tools: [AIToolDefinition] = [
        AIToolDefinition(
            name: "kurth_split",
            description: "Split de la ventana activa. action: open pone tabId en el panel derecho (abre el split junto a la pestaña elegida, o reemplaza el derecho); close cierra el split y deja a la vista el panel activo; follow enciende o apaga (on, true por defecto) que el panel derecho cargue los links del izquierdo — con tabId primero lo pone a la derecha; status dice qué hay. Ids de list_tabs.",
            parameters: ["type": "object", "properties": [
                "action": ["type": "string", "enum": ["open", "close", "follow", "status"]],
                "tabId": ["type": "string"],
                "on": ["type": "boolean"],
            ], "required": ["action"]]
        ),
    ]

    /// nil si la herramienta no es del split.
    static func llamar(_ name: String, _ args: [String: Any], window: BrowserWindowState, tabs: TabsController) -> [String: Any]? {
        guard name == "kurth_split" else { return nil }
        guard let bm else { return texto("El split no está registrado", error: true) }
        let sm = bm.splitManager
        let gancho = KurthSplitGancho.shared
        let tabId = (args["tabId"] as? String).flatMap(UUID.init(uuidString:))
        if let raw = args["tabId"] as? String, tabId == nil { return texto("tabId no válido: \(raw). Usa list_tabs.", error: true) }
        if let tabId, tabs.item(tabId) == nil { return texto("No encontré la pestaña \(tabId). Usa list_tabs.", error: true) }

        switch args["action"] as? String {
        case "open":
            guard let tabId else { return texto("open necesita tabId", error: true) }
            guard window.split != nil || tabs.selectedItemID(in: window) != tabId else {
                return texto("Esa es la pestaña elegida; open toma la que va a la derecha", error: true)
            }
            sm.enterSplit(with: tabId, placeOn: .right, in: window)
        case "close":
            guard sm.isSplit(for: window.id) else { return texto("No hay split", error: true) }
            sm.separate(in: window)
        case "follow":
            let activo = (args["on"] as? Bool) ?? true
            if let tabId, window.split?.rightItemID != tabId {
                guard window.split?.leftItemID != tabId else { return texto("Esa pestaña es el panel izquierdo", error: true) }
                guard window.split != nil || tabs.selectedItemID(in: window) != tabId else {
                    return texto("Esa es la pestaña elegida; follow toma la que va a la derecha", error: true)
                }
                sm.enterSplit(with: tabId, placeOn: .right, in: window)
            }
            guard let derecha = window.split?.rightItemID else { return texto("No hay split: da tabId para abrirlo", error: true) }
            gancho.seguir(derecha, en: window, activo)
        case "status":
            break
        default:
            return texto("action: open, close, follow o status", error: true)
        }
        return texto(json(estado(window: window, tabs: tabs)))
    }

    private static func estado(window: BrowserWindowState, tabs: TabsController) -> [String: Any] {
        func pestaña(_ id: UUID?) -> Any {
            guard let id, let item = tabs.item(id) else { return NSNull() }
            return ["id": id.uuidString, "title": tabs.title(for: item), "url": tabs.currentURL(for: item)?.absoluteString ?? ""]
        }
        var resultado: [String: Any] = [
            "isSplit": window.split != nil,
            "left": pestaña(window.split?.leftItemID),
            "right": pestaña(window.split?.rightItemID),
            "sigue": window.split.map { KurthSplitGancho.shared.sigue($0.rightItemID, en: window) } ?? false,
            "selected": pestaña(tabs.selectedItemID(in: window)),
            "ajustes": ["kurth.splitEdgeWidth": anchoDeOrilla, "kurth.splitOptionClick": clicConOpcionActivo],
        ]
        if let lado = bm?.splitManager.activeSide(for: window.id) {
            resultado["activeSide"] = lado == .left ? "left" : "right"
        }
        return resultado
    }

    private static func texto(_ s: String, error: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": s]], "isError": error]
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Zona de orilla

/// La franja translúcida en la orilla derecha de la página mientras se arrastra una pestaña. Sube
/// al color del Space cuando el arrastre está dentro. Va sobre la vista previa de upstream
/// (WebsiteView.SplitPreviewOverlay), que ya aparece con cualquier arrastre sobre la página.
struct KurthSplitZonaDeOrilla: View {
    @EnvironmentObject private var splitManager: SplitViewManager
    @EnvironmentObject private var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    var body: some View {
        GeometryReader { geo in
            let estado = splitManager.getSplitState(for: windowState.id)
            let ancho = KurthSplit.anchoDeOrilla
            let dentro = estado.dragLocation.map { $0.x >= geo.size.width - ancho } ?? false
            let activa = dentro && estado.previewSide == .right
            let acento = browserManager.gradientColorManager.accentColor
            RoundedRectangle(cornerRadius: NookDesign.Radius.md, style: .continuous)
                .fill(activa ? acento.opacity(0.28) : Color.primary.opacity(0.07))
                .overlay {
                    Image(systemName: "rectangle.righthalf.filled")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(activa ? AnyShapeStyle(acento) : AnyShapeStyle(.secondary))
                }
                .frame(width: max(ancho - 8, 12))
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .animation(NookDesign.Motion.quick, value: activa)
        }
        .allowsHitTesting(false)
    }
}
