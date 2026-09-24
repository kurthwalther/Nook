// Licensed under GPL-3.0. See LICENSE.
//
//  KurthAgentService.swift
//  Nook (rama kurth)
//
//  El estado del chat cuando quien contesta es un agente de línea de comandos por ACP
//  (KurthACPClient), en vez de una API con llave propia. Reemplaza a AIService en el panel
//  lateral; AIService sigue en el proyecto, desconectado, hasta que esto lleve tiempo probado.
//
//  Tres cosas que el chat anterior no hacía y aquí sí, porque con un agente se notan:
//   1. El texto aparece mientras llega. AIService acumulaba en `streamingText` y ninguna vista
//      lo leía, así que la respuesta salía de golpe al final.
//   2. Las herramientas quedan en la conversación, con su estado. Antes había un "Using X…"
//      que desaparecía y no dejaba rastro de lo que el agente tocó.
//   3. El permiso se responde dentro del chat. Antes era un NSAlert que congelaba la ventana.
//
//  Quién ejecuta qué: el agente ejecuta sus propias herramientas; Nook solo autoriza. Por eso
//  aquí no hay bucle de llamadas a herramientas como en AIService.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class KurthAgentService {

    // MARK: - Lo que la vista pinta

    struct Herramienta: Identifiable, Equatable {
        let id: String
        var titulo: String
        /// "read", "edit", "execute", "search", "fetch", "think", "other".
        var kind: String
        /// "pending", "in_progress", "completed", "failed".
        var estado: String

        var terminada: Bool { estado == "completed" || estado == "failed" }
        var falló: Bool { estado == "failed" }
    }

    struct Mensaje: Identifiable {
        enum Autor { case usuario, agente }
        let id = UUID()
        let autor: Autor
        var texto: String
        var herramientas: [Herramienta] = []
        var enCurso = false
        let hora = Date()
    }

    /// Una autorización esperando respuesta del usuario. Mientras exista, el agente está
    /// detenido: no hay tiempo límite del lado del protocolo.
    struct Permiso: Identifiable {
        let id = UUID()
        let titulo: String
        let kind: String
        let opciones: [KurthACPPermission.Option]
        /// Se llama con el id de la opción elegida, o nil para cancelar.
        let responder: (String?) -> Void
    }

    enum Estado: Equatable {
        case apagado
        case arrancando
        case listo
        case trabajando
        case error(String)

        var puedeEscribir: Bool { self == .listo }
    }

    private(set) var mensajes: [Mensaje] = []
    private(set) var estado: Estado = .apagado
    private(set) var permiso: Permiso?
    /// El plan que el agente publica y va actualizando mientras trabaja.
    private(set) var plan: [String] = []
    /// Última línea de diagnóstico del subproceso; sirve para saber por qué no arranca.
    private(set) var ultimoDiagnostico: String?
    /// Lo que el agente ofrece con «/»: sus comandos y cada skill del usuario.
    private(set) var comandos: [KurthACPCommand] = []
    private(set) var modos: [(id: String, name: String)] = []
    private(set) var modoActual: String?

    /// Carpeta desde la que trabaja el agente: la elige el usuario y se recuerda entre
    /// arranques. Decide dos cosas que se notan enseguida — qué memorias lee (el CLAUDE.md que
    /// haya ahí y los de encima) y sobre qué archivos actúa. Por eso apuntarla a un proyecto
    /// hace que el agente "sepa" de ese proyecto, y apuntarla a la carpeta personal deja un
    /// agente genérico con las memorias del usuario.
    private(set) var carpetaDeTrabajo: URL = KurthAgentService.carpetaGuardada()

    /// Las últimas carpetas usadas, para el menú. La personal siempre va primero.
    private(set) var carpetasRecientes: [URL] = KurthAgentService.recientesGuardadas()

    private static let claveCarpeta = "kurth.agentFolder"
    private static let claveRecientes = "kurth.agentRecentFolders"

    static func carpetaGuardada() -> URL {
        let personal = FileManager.default.homeDirectoryForCurrentUser
        guard let ruta = UserDefaults.standard.string(forKey: claveCarpeta) else { return personal }
        var esDirectorio: ObjCBool = false
        guard FileManager.default.fileExists(atPath: ruta, isDirectory: &esDirectorio), esDirectorio.boolValue
        else { return personal }   // la carpeta pudo borrarse o moverse desde la última vez
        return URL(fileURLWithPath: ruta)
    }

    static func recientesGuardadas() -> [URL] {
        let personal = FileManager.default.homeDirectoryForCurrentUser
        let guardadas = (UserDefaults.standard.array(forKey: claveRecientes) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return ([personal] + guardadas.filter { $0.path != personal.path }).prefix(6).map { $0 }
    }

    /// Cambia dónde trabaja el agente. El cwd se fija al abrir la sesión, así que hay que
    /// rehacerla; la conversación se conserva aunque el agente ya no la recuerde.
    func cambiarCarpeta(_ url: URL) {
        guard url.path != carpetaDeTrabajo.path else { return }
        carpetaDeTrabajo = url
        UserDefaults.standard.set(url.path, forKey: Self.claveCarpeta)

        var recientes = carpetasRecientes.map(\.path).filter { $0 != url.path }
        recientes.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(recientes.prefix(6)), forKey: Self.claveRecientes)
        carpetasRecientes = Self.recientesGuardadas()

        apagar()
        arrancar()
    }

    private let cliente = KurthACPClient()
    private var arrancando: Task<Void, Never>?

    // MARK: - Ciclo de vida

    /// Arranca el agente y abre la sesión. Tarda varios segundos, así que se llama al abrir el
    /// panel y no al mandar el primer mensaje.
    func arrancar() {
        guard estado == .apagado || esError else { return }
        arrancando?.cancel()
        estado = .arrancando
        conectarEventos()

        arrancando = Task { [weak self] in
            guard let self else { return }
            do {
                guard let ejecutable = Self.buscarNpx() else {
                    self.estado = .error("No encontré npx. El agente necesita Node instalado.")
                    return
                }
                try await self.cliente.start(agent: .claudeCode(npx: ejecutable))
                try await self.cliente.newSession(cwd: self.carpetaDeTrabajo,
                                                  mcpServers: Self.mcpDeNook())
                self.modos = self.cliente.availableModes
                self.modoActual = self.cliente.currentModeId
                self.estado = .listo
            } catch {
                self.estado = .error(error.localizedDescription)
            }
        }
    }

    func apagar() {
        arrancando?.cancel()
        arrancando = nil
        permiso?.responder(nil)
        permiso = nil
        cliente.stop()
        estado = .apagado
    }

    /// Los comandos que empatan con lo que se lleva escrito tras la «/».
    func comandos(queEmpiecenCon prefijo: String) -> [KurthACPCommand] {
        let busqueda = prefijo.lowercased()
        return comandos
            .filter { busqueda.isEmpty || $0.name.lowercased().contains(busqueda) }
            .sorted { a, b in
                // Primero los que empiezan igual: escribir "mo" debe ofrecer /model antes que
                // cualquier skill que lleve "mo" en medio.
                let ea = a.name.lowercased().hasPrefix(busqueda), eb = b.name.lowercased().hasPrefix(busqueda)
                return ea == eb ? a.name.count < b.name.count : ea
            }
    }

    func limpiar() {
        mensajes.removeAll()
        plan.removeAll()
    }

    // MARK: - Conversación

    func enviar(_ texto: String) {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty, estado == .listo else { return }

        mensajes.append(Mensaje(autor: .usuario, texto: limpio))
        mensajes.append(Mensaje(autor: .agente, texto: "", enCurso: true))
        plan.removeAll()
        estado = .trabajando

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.cliente.prompt(limpio)
            } catch {
                self.anexarAlAgente("\n\n⚠️ \(error.localizedDescription)")
            }
            self.cerrarTurno()
        }
    }

    /// Interrumpe el turno. El agente conserva la sesión y lo ya dicho.
    func cancelar() {
        guard estado == .trabajando else { return }
        cliente.cancel()
    }

    func responderPermiso(_ opcionId: String?) {
        guard let permiso else { return }
        self.permiso = nil
        permiso.responder(opcionId)
    }

    // MARK: - Eventos del agente

    private func conectarEventos() {
        cliente.onEvent = { [weak self] evento in
            guard let self else { return }
            switch evento {
            case .messageChunk(let texto):
                self.anexarAlAgente(texto)

            case .thoughtChunk:
                // El razonamiento no se pinta todavía: primero hay que decidir cómo se ve sin
                // robarle espacio a la respuesta.
                break

            case .toolStarted(let id, let titulo, let kind):
                self.actualizarHerramienta(id: id, titulo: titulo, kind: kind, estado: "in_progress")

            case .toolUpdated(let id, let estadoNuevo):
                self.actualizarHerramienta(id: id, titulo: nil, kind: nil, estado: estadoNuevo)

            case .plan(let pasos):
                self.plan = pasos

            case .commands(let lista):
                self.comandos = lista

            case .diagnostic(let texto):
                self.ultimoDiagnostico = texto

            case .turnEnded:
                self.cerrarTurno()

            case .failed(let motivo):
                self.estado = .error(motivo)
                self.cerrarTurno()
            }
        }

        cliente.onPermission = { [weak self] pedido in
            guard let self else { return nil }
            return await withCheckedContinuation { continuation in
                // El agente queda detenido hasta que la vista conteste. Se guarda aquí para que
                // el botón del chat sea el que responda, en vez de un diálogo del sistema.
                self.permiso = Permiso(titulo: pedido.toolTitle,
                                       kind: pedido.toolKind,
                                       opciones: pedido.options,
                                       responder: { continuation.resume(returning: $0) })
            }
        }
    }

    private func anexarAlAgente(_ texto: String) {
        guard !texto.isEmpty else { return }
        if let indice = indiceDelTurno {
            mensajes[indice].texto += texto
        } else {
            mensajes.append(Mensaje(autor: .agente, texto: texto, enCurso: true))
        }
    }

    private func actualizarHerramienta(id: String, titulo: String?, kind: String?, estado: String) {
        guard let indice = indiceDelTurno else { return }
        if let existente = mensajes[indice].herramientas.firstIndex(where: { $0.id == id }) {
            if let titulo { mensajes[indice].herramientas[existente].titulo = titulo }
            if let kind { mensajes[indice].herramientas[existente].kind = kind }
            mensajes[indice].herramientas[existente].estado = estado
        } else {
            mensajes[indice].herramientas.append(
                Herramienta(id: id, titulo: titulo ?? "herramienta", kind: kind ?? "other", estado: estado))
        }
    }

    /// El mensaje del agente que se está escribiendo ahora.
    private var indiceDelTurno: Int? {
        guard let ultimo = mensajes.indices.last,
              mensajes[ultimo].autor == .agente, mensajes[ultimo].enCurso else { return nil }
        return ultimo
    }

    private func cerrarTurno() {
        if let indice = indiceDelTurno {
            mensajes[indice].enCurso = false
            // Un turno que no dijo nada y no usó nada no aporta: se quita para no dejar una
            // burbuja vacía cuando el usuario cancela.
            if mensajes[indice].texto.isEmpty && mensajes[indice].herramientas.isEmpty {
                mensajes.remove(at: indice)
            }
        }
        permiso?.responder(nil)
        permiso = nil
        if case .error = estado {} else if cliente.isRunning {
            estado = .listo
        }
    }

    private var esError: Bool { if case .error = estado { return true }; return false }

    // MARK: - Entorno

    /// El MCP de desarrollo de Nook, si el usuario lo tiene encendido. Es lo que le permite al
    /// agente manejar el propio navegador; sin el token, el servidor no está sirviendo.
    private static func mcpDeNook() -> [KurthACPMCPServer] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let archivo = base.appendingPathComponent("com.gstudios.nook/dev-mcp-token")
        guard let token = try? String(contentsOf: archivo, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
            let url = URL(string: "http://127.0.0.1:\(DevMCPServer.port.rawValue)/mcp") else { return [] }
        return [KurthACPMCPServer(name: "nook", url: url,
                                  headers: [(name: "Authorization", value: "Bearer \(token)")])]
    }

    /// Una app lanzada desde el Finder no hereda el PATH del shell, así que `npx` no aparece
    /// donde aparecería en una terminal. Se busca donde suele estar y, si no, se le pregunta al
    /// shell de inicio de sesión, que es lo único que conoce los cambios de PATH del usuario.
    private static func buscarNpx() -> String? {
        let candidatos = ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"]
        let fm = FileManager.default
        if let directo = candidatos.first(where: { fm.isExecutableFile(atPath: $0) }) { return directo }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: shell)
        proceso.arguments = ["-lc", "command -v npx"]
        let salida = Pipe()
        proceso.standardOutput = salida
        proceso.standardError = FileHandle.nullDevice
        guard (try? proceso.run()) != nil else { return nil }
        proceso.waitUntilExit()
        let ruta = String(decoding: salida.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: ruta) ? ruta : nil
    }
}
