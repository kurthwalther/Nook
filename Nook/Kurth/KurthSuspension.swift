// Licensed under GPL-3.0. See LICENSE.
//
//  KurthSuspension.swift
//  Nook (rama kurth)
//
//  Suspensión de pestañas (plan del 26 sep, punto 2). Nook ya traía TabCompositorManager, que
//  descarga páginas que ninguna ventana muestra por inactividad, presupuesto de páginas y presión
//  de memoria; esta capa le pone la política de Kurth encima en vez de duplicarlo:
//   - El tiempo de inactividad sale de `kurth.tabSuspendMinutes` (20 por default, 0 = nunca), no
//     del modo de pestañas de Settings (que sigue mandando en presupuesto y fracción bajo presión).
//   - Fijadas y favoritos también se suspenden (upstream las eximía).
//   - Nunca se suspende: la visible en cualquier ventana (activa o en split), la que reproduce
//     audio o video, la de picture-in-picture, la que usa cámara o micrófono, la que tiene un
//     diálogo de JavaScript pendiente y la de Peek (que además vive fuera de `tabs.sessions`).
//   - Antes de soltar la vista se guarda su `interactionState` (historial atrás/adelante, scroll y
//     formularios); al volver, la página se restaura con eso en vez de pedir la URL desde cero.
//  Título, favicon y URL ya sobreviven en PageSession sin vista.
//
//  Ganchos: PageSession (KurthSuspensionGancho, en NookWeb), TabCompositorManager (los métodos
//  kurth*) y KurthMCPTools (`kurth_tabs_memory` para probar sin mouse).
//

import Foundation
import WebKit
import NookTabsCore
import NookWeb

@MainActor
enum KurthSuspension {
    static let clave = "kurth.tabSuspendMinutes"
    static let minutosDefault = 20.0
    /// Un interactionState más grande que esto no se guarda: la suspensión existe para soltar
    /// memoria, no para moverla de lugar.
    static let topeEstado = 4 * 1024 * 1024

    private struct Guardado {
        let url: URL
        let estado: Any
        let fecha: Date
    }

    private static var guardados: [UUID: Guardado] = [:]
    private static weak var browserManager: BrowserManager?

    /// Minutos configurados; 0 = nunca.
    static var minutos: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: clave) != nil else { return minutosDefault }
        return max(0, defaults.double(forKey: clave))
    }

    /// Inactividad tras la que se suspende; nil = nunca.
    static var timeout: TimeInterval? {
        let m = minutos
        return m > 0 ? m * 60 : nil
    }

    /// Lo llama BrowserManager al construirse: llena los ganchos de PageSession.
    static func registrar(browserManager bm: BrowserManager) {
        browserManager = bm
        KurthSuspensionGancho.guardar = { guardar($0) }
        KurthSuspensionGancho.estadoGuardado = { estadoGuardado(para: $0) }
        KurthSuspensionGancho.olvidar = { guardados[$0] = nil }
    }

    /// Cambió `kurth.tabSuspendMinutes` en vivo: los temporizadores se rearman con el valor nuevo.
    static func ajusteCambio() {
        browserManager?.compositorManager.kurthTimeoutChanged()
    }

    // MARK: - interactionState

    private static func guardar(_ session: PageSession) {
        guard let view = session.webView, let estado = view.interactionState else {
            guardados[session.itemID] = nil
            return
        }
        // En macOS el estado llega como NSData. Si un día cambia de tipo se guarda igual.
        if let data = estado as? Data, data.count > topeEstado {
            guardados[session.itemID] = nil
            return
        }
        guardados[session.itemID] = Guardado(url: session.url, estado: estado, fecha: Date())
    }

    /// El estado guardado si sigue valiendo para la URL que la página va a cargar; se consume.
    private static func estadoGuardado(para session: PageSession) -> Any? {
        guard let g = guardados.removeValue(forKey: session.itemID) else { return nil }
        // Alguien cambió la URL mientras estaba suspendida (una extensión, por ejemplo): el
        // estado guardado llevaría a la página vieja.
        return g.url == session.url ? g.estado : nil
    }

    static func tieneEstadoGuardado(_ itemID: UUID) -> Bool { guardados[itemID] != nil }

    // MARK: - Exenciones

    /// Por qué una página no se suspende ahora, o nil si sí puede. Es la lista completa: la del
    /// compositor (visible, medios, captura) más las de esta capa (diálogo pendiente, Peek).
    static func motivoExenta(_ session: PageSession, tabs: TabsController) -> String? {
        if session.isUnloaded { return "ya está suspendida" }
        if tabs.isVisibleInAnyWindow(session.itemID) { return "visible en una ventana (activa o split)" }
        if tabs.isOnScreen(session.itemID) || session.hasPiPActive { return "en picture-in-picture" }
        if session.hasPlayingVideo || session.hasPlayingAudio || session.hasAudioContent { return "reproduce audio o video" }
        var vistas = browserManager?.webViewCoordinator?.getAllWebViews(for: session.itemID) ?? []
        if let primaria = session.webView { vistas.append(primaria) }
        if vistas.contains(where: { $0.cameraCaptureState != .none || $0.microphoneCaptureState != .none }) {
            return "usa cámara o micrófono"
        }
        if vistas.contains(where: { KurthDialogs.pendiente($0) != nil }) { return "tiene un diálogo pendiente" }
        if let peek = browserManager?.peekManager.page, peek === session { return "es la página de Peek" }
        return nil
    }

    // MARK: - MCP

    static let herramienta = AIToolDefinition(
        name: "kurth_tabs_memory",
        description: "Pestañas y su memoria. list: cada pestaña con tabId, estado (cargada, suspendida o sin página), si está visible, por qué no se puede suspender y minutos sin uso. suspend: suelta la vista de una pestaña por tabId respetando las exenciones. restore: la vuelve a cargar sin seleccionarla, con su scroll y formularios si se guardaron.",
        parameters: ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["list", "suspend", "restore"]],
            "tabId": ["type": "string", "description": "suspend y restore: el UUID que da list"],
        ]]
    )

    /// nil si la herramienta no es esta.
    static func llamar(_ name: String, _ args: [String: Any], tabs: TabsController) -> [String: Any]? {
        guard name == "kurth_tabs_memory" else { return nil }
        let action = (args["action"] as? String) ?? "list"
        guard action == "suspend" || action == "restore" else {
            return KurthMCPTools.text(KurthMCPTools.json(listado(tabs: tabs)))
        }
        guard let raw = args["tabId"] as? String, let id = UUID(uuidString: raw) else {
            return KurthMCPTools.text("\(action) necesita tabId (el UUID de list)", error: true)
        }
        guard let item = tabs.item(id) else { return KurthMCPTools.text("No hay pestaña \(raw)", error: true) }
        guard let compositor = browserManager?.compositorManager else {
            return KurthMCPTools.text("BrowserManager no está listo", error: true)
        }
        if action == "suspend" {
            guard let session = tabs.session(for: id), !session.isUnloaded else {
                return KurthMCPTools.text("Ya estaba suspendida (sin vista)")
            }
            if let motivo = motivoExenta(session, tabs: tabs) {
                return KurthMCPTools.text("No se suspende: \(motivo)", error: true)
            }
            compositor.kurthSuspend(session)
        } else {
            guard let session = tabs.ensureSession(for: id) else {
                return KurthMCPTools.text("No se pudo crear la página", error: true)
            }
            if !session.isUnloaded { return KurthMCPTools.text("Ya estaba cargada") }
            // Igual que el calentamiento de arranque: carga sin seleccionar y marca el acceso.
            compositor.load(session)
        }
        return KurthMCPTools.text(KurthMCPTools.json(fila(item, seccion: seccion(de: id, tabs: tabs), tabs: tabs)))
    }

    private static func seccion(de id: UUID, tabs: TabsController) -> String {
        switch tabs.section(of: id) {
        case .favorites: return "favoritos"
        case .pinned: return "guardados"
        case .tabs: return "pestañas"
        case .folder(let padre): return seccion(de: padre, tabs: tabs)
        case nil: return "?"
        }
    }

    private static func fila(_ item: Item, seccion: String, tabs: TabsController) -> [String: Any] {
        let session = tabs.session(for: item.id)
        let estado: String
        if let session { estado = session.isUnloaded ? "suspendida" : "cargada" } else { estado = "sin página" }
        var fila: [String: Any] = [
            "tabId": item.id.uuidString,
            "titulo": tabs.title(for: item),
            "url": tabs.currentURL(for: item)?.absoluteString ?? NSNull(),
            "seccion": seccion,
            "estado": estado,
            "visible": tabs.isOnScreen(item.id),
            "estadoGuardado": guardados[item.id] != nil,
        ]
        if let session, !session.isUnloaded {
            if let motivo = motivoExenta(session, tabs: tabs) { fila["exenta"] = motivo }
            if let acceso = browserManager?.compositorManager.kurthLastAccess(item.id) {
                fila["inactivaMin"] = Int(Date().timeIntervalSince(acceso) / 60)
            }
        }
        return fila
    }

    private static func listado(tabs: TabsController) -> [String: Any] {
        var spaces: [[String: Any]] = []
        for space in tabs.orderedSpaces {
            var filas = tabs.favorites(of: space.id).map { fila($0, seccion: "favoritos", tabs: tabs) }
            filas += tabs.rows(space: space.id)
                .filter { !$0.item.isFolder }
                .map { fila($0.item, seccion: seccion(de: $0.item.id, tabs: tabs), tabs: tabs) }
            spaces.append(["space": space.name, "pestañas": filas])
        }
        let cargadas = tabs.sessions.filter { !$0.isUnloaded }.count
        return [
            "resumen": [
                "cargadas": cargadas,
                "suspendidas": tabs.sessions.count - cargadas,
                "minutosInactividad": minutos,
                "estadosGuardados": guardados.count,
            ],
            "spaces": spaces,
        ]
    }
}
