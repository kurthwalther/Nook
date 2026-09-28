// Licensed under GPL-3.0. See LICENSE.
//
//  KurthChats.swift
//  Nook (rama kurth)
//
//  Varias conversaciones con el agente (Kurth, 28 sep: "independientes, con sus propias reglas,
//  permisos y carpetas"; y sí, a la vez, aunque gaste más RAM). Cada una es un KurthAgentService con
//  su propio proceso, carpeta, permisos, reglas por sitio y cel; lo que comparten es lo que es del
//  navegador: sus memorias y los workflows. Aquí vive la lista y cuál enseña el panel.
//
//  La que se ve es una para toda la app, no una por ventana: con una sola lista es obvio dónde quedó
//  cada plática. Una conversación sin mensajes no se guarda ni se queda en la lista al salir de ella.
//
//  Dónde se ve (KurthChatsLista.swift): el título de la conversación a la izquierda del encabezado
//  del panel abre la lista; ✎ a la derecha empieza una nueva.
//

import Foundation
import Observation

@MainActor
@Observable
final class KurthChats {
    static let shared = KurthChats()

    /// Todas, en cualquier orden; `lista` las da por última actividad.
    private(set) var chats: [KurthAgentService]
    /// La que enseña el panel en todas las ventanas.
    private(set) var activo: KurthAgentService

    private static let claveActivo = "kurth.chatActivo"

    private init() {
        KurthAgentService.migrarConversacionUnica()
        var cargados = KurthAgentService.cargarGuardadas()
        let guardado = UserDefaults.standard.string(forKey: Self.claveActivo).flatMap(UUID.init(uuidString:))
        let activo: KurthAgentService
        if let elegida = cargados.first(where: { $0.id == guardado }) {
            activo = elegida
        } else if let reciente = cargados.max(by: { $0.ultimaActividad < $1.ultimaActividad }) {
            activo = reciente
        } else {
            activo = KurthAgentService(como: nil)
        }
        if !cargados.contains(where: { $0 === activo }) { cargados.append(activo) }
        chats = cargados
        self.activo = activo
    }

    /// La más reciente primero.
    var lista: [KurthAgentService] {
        chats.sorted { $0.ultimaActividad > $1.ultimaActividad }
    }

    func chat(_ id: UUID) -> KurthAgentService? {
        chats.first { $0.id == id }
    }

    // MARK: - Cambiar

    /// Una conversación nueva con la carpeta, los permisos y las reglas de la que estaba abierta. Si
    /// la abierta sigue vacía, es ella misma: no se apilan conversaciones en blanco.
    @discardableResult
    func nueva() -> KurthAgentService {
        guard !activo.mensajes.isEmpty else { return activo }
        let nueva = KurthAgentService(como: activo)
        chats.append(nueva)
        elegir(nueva)
        return nueva
    }

    func elegir(_ chat: KurthAgentService) {
        guard chat !== activo else { return }
        let anterior = activo
        activo = chat
        UserDefaults.standard.set(chat.id.uuidString, forKey: Self.claveActivo)
        // Los números de lo señalado ([Señalado N]) son de cada plática.
        KurthSenalar.shared.reiniciarNumeros()
        // La que se deja vacía no se queda en la lista (y su agente, si abrió, se apaga).
        if anterior.mensajes.isEmpty, anterior.estado != .trabajando {
            quitar(anterior)
        }
    }

    /// Clic derecho › Borrar. Si era la que se veía, pasa a la más reciente de las demás o, si no
    /// queda ninguna, a una nueva vacía.
    func borrar(_ chat: KurthAgentService) {
        if chat === activo {
            let siguiente = lista.first { $0 !== chat } ?? KurthAgentService(como: chat)
            if !chats.contains(where: { $0 === siguiente }) { chats.append(siguiente) }
            activo = siguiente
            UserDefaults.standard.set(siguiente.id.uuidString, forKey: Self.claveActivo)
            KurthSenalar.shared.reiniciarNumeros()
        }
        quitar(chat)
    }

    private func quitar(_ chat: KurthAgentService) {
        chat.descartar()
        chats.removeAll { $0 === chat }
    }

    // MARK: - Lo que preguntan los demás

    /// Algún panel (fijo o flotante, en cualquier ventana) enseña alguna conversación.
    var hayPanelAbierto: Bool {
        chats.contains { $0.panelesAbiertos > 0 }
    }

    func alguienTrabaja(salvo excepto: KurthAgentService? = nil) -> Bool {
        chats.contains { $0 !== excepto && $0.estado == .trabajando }
    }

    var trabajando: [KurthAgentService] {
        chats.filter { $0.estado == .trabajando }
    }

    /// Detener (la cápsula del modo con cabeza) para todas las que trabajan: el MCP no dice cuál de
    /// ellas está tocando la página, y detener es para que nada siga actuando.
    func detenerTodas() {
        trabajando.forEach { $0.cancelar() }
    }

    enum Aviso { case pidePermiso, respondio }

    /// Lo que otra conversación (no `chat`) tiene para Kurth, lo más urgente primero: un permiso
    /// esperando o una respuesta que no ha visto. Es el punto junto al título del panel.
    func aviso(fueraDe chat: KurthAgentService) -> Aviso? {
        let otras = chats.filter { $0 !== chat }
        if otras.contains(where: { $0.permiso != nil }) { return .pidePermiso }
        if otras.contains(where: \.sinLeer) { return .respondio }
        return nil
    }

    // MARK: - MCP

    static let herramienta = AIToolDefinition(
        name: "kurth_chats",
        description: "Conversaciones del panel del agente (cada una con su propio agente, carpeta, permisos, reglas por sitio y cel). list: todas, la más reciente primero, con id, título, estado, carpeta, modo y si es la que se ve. new: una nueva (copia carpeta y permisos de la abierta; folder la cambia) y la deja a la vista. select: enseña la de id. rename: le pone title. delete: la borra. send: manda text a la de id (o a la que se ve) como desde su caja; la arranca si está apagada.",
        parameters: ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["list", "new", "select", "rename", "delete", "send"]],
            "id": ["type": "string", "description": "El id que da list"],
            "title": ["type": "string"],
            "text": ["type": "string"],
            "folder": ["type": "string", "description": "new: ruta de la carpeta de trabajo"],
        ], "required": ["action"]]
    )

    /// nil si la herramienta no es esta.
    static func llamar(_ name: String, _ args: [String: Any]) -> [String: Any]? {
        guard name == "kurth_chats" else { return nil }
        let chats = shared
        let elegido = (args["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap(chats.chat)
        if args["id"] != nil, elegido == nil { return KurthMCPTools.text("No hay conversación con ese id", error: true) }
        switch (args["action"] as? String) ?? "list" {
        case "new":
            let nueva = chats.nueva()
            if let ruta = args["folder"] as? String {
                nueva.cambiarCarpeta(URL(fileURLWithPath: (ruta as NSString).expandingTildeInPath))
            }
            return KurthMCPTools.text(KurthMCPTools.json(fila(nueva)))
        case "select":
            guard let elegido else { return KurthMCPTools.text("select necesita id", error: true) }
            chats.elegir(elegido)
        case "rename":
            guard let elegido, let titulo = args["title"] as? String else { return KurthMCPTools.text("rename necesita id y title", error: true) }
            let limpio = titulo.trimmingCharacters(in: .whitespacesAndNewlines)
            elegido.tituloPuesto = limpio.isEmpty ? nil : limpio
        case "delete":
            guard let elegido else { return KurthMCPTools.text("delete necesita id", error: true) }
            chats.borrar(elegido)
        case "send":
            let agente = elegido ?? chats.activo
            guard let texto = args["text"] as? String, !texto.isEmpty else { return KurthMCPTools.text("send necesita text", error: true) }
            agente.arrancar()
            guard agente.aceptaMensajes else { return KurthMCPTools.text("Esa conversación no acepta mensajes ahora", error: true) }
            agente.enviar(texto)
            return KurthMCPTools.text(KurthMCPTools.json(fila(agente)))
        default:
            break
        }
        return KurthMCPTools.text(KurthMCPTools.json(chats.lista.map(fila)))
    }

    private static func fila(_ chat: KurthAgentService) -> [String: Any] {
        let estado: String
        switch chat.estado {
        case .apagado: estado = "apagado"
        case .arrancando: estado = "arrancando"
        case .listo: estado = "listo"
        case .trabajando: estado = chat.permiso == nil ? "trabajando" : "esperando permiso"
        case .error(let motivo): estado = "error: " + motivo
        }
        return [
            "id": chat.id.uuidString,
            "titulo": chat.titulo,
            "activo": chat === shared.activo,
            "estado": estado,
            "carpeta": chat.carpetaDeTrabajo.path,
            "modo": (chat.modoActual ?? chat.elegidas["mode"]).map { $0 as Any } ?? NSNull(),
            "reglasPorSitio": chat.usaReglas ? chat.reglas.count : 0,
            "cel": chat.remoto.encendido,
            "sinLeer": chat.sinLeer,
            "mensajes": chat.mensajes.count,
            "paneles": chat.panelesAbiertos,
            "ultimaActividad": ISO8601DateFormatter().string(from: chat.ultimaActividad),
            "ultimoMensaje": String((chat.mensajes.last?.texto ?? "").suffix(300)),
        ]
    }
}
