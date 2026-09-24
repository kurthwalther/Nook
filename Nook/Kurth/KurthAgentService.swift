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

    struct Herramienta: Identifiable, Equatable, Codable {
        let id: String
        var titulo: String
        /// "read", "edit", "execute", "search", "fetch", "think", "other".
        var kind: String
        /// "pending", "in_progress", "completed", "failed".
        var estado: String

        var terminada: Bool { estado == "completed" || estado == "failed" }
        var falló: Bool { estado == "failed" }
    }

    struct Mensaje: Identifiable, Codable {
        enum Autor: String, Codable { case usuario, agente }
        var id = UUID()
        let autor: Autor
        var texto: String
        var herramientas: [Herramienta] = []
        var enCurso = false
        var hora = Date()
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
    /// Modelo, esfuerzo, modo y rápido, tal como los publica el agente (ver KurthACPConfigOption).
    private(set) var opciones: [KurthACPConfigOption] = []

    /// Lo que el usuario eligió de modelo, esfuerzo y rápido; se vuelve a aplicar en cada sesión.
    /// El modo de permisos NO se guarda a propósito: vuelve a Manual, como en el CLI. Un "sin
    /// permisos" pegado entre sesiones es justo lo que aprovecharía una página con instrucciones
    /// escondidas para el agente.
    private static let claveOpciones = "kurth.agentOptions"
    private static let opcionesQueSeRecuerdan: Set<String> = ["model", "effort", "fast"]

    func cambiarOpcion(_ id: String, a valor: String) {
        if Self.opcionesQueSeRecuerdan.contains(id) {
            var elegidas = UserDefaults.standard.dictionary(forKey: Self.claveOpciones) as? [String: String] ?? [:]
            elegidas[id] = valor
            UserDefaults.standard.set(elegidas, forKey: Self.claveOpciones)
        }
        Task {
            do { try await cliente.setConfigOption(id, value: valor) } catch { ultimoDiagnostico = error.localizedDescription }
            opciones = cliente.configOptions
            modoActual = cliente.currentModeId
        }
    }

    private func aplicarOpcionesGuardadas() async {
        var elegidas = UserDefaults.standard.dictionary(forKey: Self.claveOpciones) as? [String: String] ?? [:]
        // Si el usuario no ha elegido esfuerzo en el panel, arranca en bajo: el panel es para
        // preguntas rápidas y en xhigh Opus se pone a verificar (24 sep: 17 s para resumir una nota).
        if elegidas["effort"] == nil { elegidas["effort"] = "low" }
        // El modelo primero: de él dependen las demás (con Sonnet no existe "fast").
        for id in ["model", "effort", "fast"] {
            guard let valor = elegidas[id], let opcion = cliente.configOptions.first(where: { $0.id == id }),
                  opcion.currentValue != valor,
                  opcion.choices.contains(where: { $0.value == valor }) else { continue }
            try? await cliente.setConfigOption(id, value: valor)
        }
        opciones = cliente.configOptions
    }

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

        sesionParaRetomar = nil
        apagar()
        arrancar()
    }

    private let cliente = KurthACPClient()
    private var arrancando: Task<Void, Never>?

    // MARK: - Apagado cuando nadie lo usa

    /// Paneles del agente abiertos, sumando todas las ventanas (el servicio es uno para la app).
    /// Con cero, el agente se apaga tras `esperaAntesDeApagar`: pesa ~420 MB, 1.3 GB con los MCP
    /// de Kurth, y en la Air de 8 GB eso no puede quedarse vivo con el panel cerrado.
    private var panelesAbiertos = 0
    private var apagadoProgramado: Task<Void, Never>?
    /// La conversación que se apagó por inactividad, para retomarla (session/resume) al reabrir.
    /// Solo vale para la misma carpeta: el cwd se fija al abrir la sesión.
    private var sesionParaRetomar: (id: String, carpeta: String)?
    /// Abrir y cerrar el panel seguido no debe reiniciar el agente cada vez.
    static let esperaAntesDeApagar: Duration = .seconds(30)

    func panelAbierto() {
        panelesAbiertos += 1
        apagadoProgramado?.cancel()
        apagadoProgramado = nil
        arrancar()
    }

    func panelCerrado() {
        panelesAbiertos = max(0, panelesAbiertos - 1)
        programarApagado()
    }

    private func programarApagado() {
        guard panelesAbiertos == 0, estado != .apagado else { return }
        apagadoProgramado?.cancel()
        apagadoProgramado = Task { [weak self] in
            try? await Task.sleep(for: Self.esperaAntesDeApagar)
            guard !Task.isCancelled else { return }
            self?.apagarSiNadieLoUsa()
        }
    }

    private func apagarSiNadieLoUsa() {
        guard panelesAbiertos == 0 else { return }
        // A media respuesta o esperando un permiso no se corta: cerrarTurno lo vuelve a intentar.
        guard estado != .trabajando, permiso == nil else { return }
        if let id = cliente.sessionId { sesionParaRetomar = (id, carpetaDeTrabajo.path) }
        guardarConversacion()
        apagar()
    }

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
                var agente = KurthACPAgent.claudeCode(npx: ejecutable)
                if let path = await Task.detached(operation: { Self.pathDeInicioDeSesion() }).value {
                    agente.environment["PATH"] = path
                }
                self.ultimoDiagnostico = nil
                try await self.cliente.start(agent: agente)
                if let anterior = self.sesionParaRetomar, anterior.carpeta == self.carpetaDeTrabajo.path {
                    do {
                        try await self.cliente.resumeSession(anterior.id, cwd: self.carpetaDeTrabajo,
                                                             mcpServers: Self.mcpDeNook(), instrucciones: Self.instrucciones)
                    } catch {
                        try await self.cliente.newSession(cwd: self.carpetaDeTrabajo,
                                                          mcpServers: Self.mcpDeNook(), instrucciones: Self.instrucciones)
                        // Lo de arriba sigue en pantalla, pero el agente ya no lo recuerda: se dice.
                        if !self.mensajes.isEmpty {
                            self.mensajes.append(Mensaje(autor: .agente, texto: "No pude retomar la conversación anterior; desde aquí es una nueva y no recuerdo lo de arriba."))
                        }
                    }
                } else {
                    self.paginasConContenido.removeAll()
                    try await self.cliente.newSession(cwd: self.carpetaDeTrabajo,
                                                      mcpServers: Self.mcpDeNook(), instrucciones: Self.instrucciones)
                }
                self.sesionParaRetomar = nil
                await self.aplicarOpcionesGuardadas()
                self.modos = self.cliente.availableModes
                self.modoActual = self.cliente.currentModeId
                self.estado = .listo
            } catch {
                // Si el proceso murió, su último mensaje de error dice por qué; "el agente no está
                // corriendo" solo dice que ya no está (así se escondió el PATH el 24 sep).
                if case .error = self.estado { return }
                let causa = self.ultimoDiagnostico.map { "\(error.localizedDescription) \($0)" }
                self.estado = .error(causa ?? error.localizedDescription)
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
        sesionParaRetomar = nil
        paginasConContenido.removeAll()
        try? FileManager.default.removeItem(at: Self.archivoGuardado)
    }

    // MARK: - Conversación guardada

    /// Lo que se ve en el chat y la sesión del agente, para que cerrar Nook no borre la plática:
    /// al abrir se pinta lo de antes y la primera sesión se retoma con session/resume, así que el
    /// agente también lo recuerda (Kurth lo pidió el 24 sep).
    private struct Guardado: Codable {
        var carpeta: String
        var sessionId: String?
        var mensajes: [Mensaje]
    }

    private static let archivoGuardado: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.gstudios.nook/Kurth/agente.json")
    }()

    init() {
        cargarConversacion()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.guardarConversacion() }
        }
    }

    private func cargarConversacion() {
        guard let datos = try? Data(contentsOf: Self.archivoGuardado),
              let guardado = try? JSONDecoder().decode(Guardado.self, from: datos) else { return }
        // Un turno que se cortó a la mitad al cerrar Nook ya no está en curso.
        mensajes = guardado.mensajes.map { var m = $0; m.enCurso = false; return m }
        if let id = guardado.sessionId, guardado.carpeta == carpetaDeTrabajo.path {
            sesionParaRetomar = (id, guardado.carpeta)
        }
    }

    private func guardarConversacion() {
        guard !mensajes.isEmpty else { return }
        let guardado = Guardado(carpeta: carpetaDeTrabajo.path,
                                sessionId: cliente.sessionId ?? sesionParaRetomar?.id,
                                mensajes: mensajes)
        guard let datos = try? JSONEncoder().encode(guardado) else { return }
        try? FileManager.default.createDirectory(at: Self.archivoGuardado.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? datos.write(to: Self.archivoGuardado, options: .atomic)
    }

    // MARK: - Conversación

    /// `pagina`: la pestaña que el usuario tiene enfrente, para que "¿qué estamos viendo?" tenga
    /// respuesta. Va como enlace (dirección y título), no el contenido: si lo necesita, el agente
    /// lee la página con el Browser Control de Nook.
    /// Páginas cuyo contenido ya se le mandó al agente en esta sesión: la segunda pregunta sobre la
    /// misma página no lo repite. Se vacía con una sesión nueva o al limpiar.
    private(set) var paginasConContenido = Set<String>()

    func enviar(_ texto: String, pagina: KurthACPResourceLink? = nil, contenido: String? = nil) {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty, estado == .listo else { return }

        mensajes.append(Mensaje(autor: .usuario, texto: limpio))
        mensajes.append(Mensaje(autor: .agente, texto: "", enCurso: true))
        plan.removeAll()
        estado = .trabajando

        Task { [weak self] in
            guard let self else { return }
            do {
                let adjuntos = contenido.flatMap { c in pagina.map { [(uri: $0.uri, texto: c)] } } ?? []
                if let uri = pagina?.uri, contenido != nil { self.paginasConContenido.insert(uri) }
                try await self.cliente.prompt(limpio, links: pagina.map { [$0] } ?? [], adjuntos: adjuntos)
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

            case .configChanged(let nuevas):
                self.opciones = nuevas
                self.modoActual = self.cliente.currentModeId
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
        guardarConversacion()
        // Si el panel se cerró mientras trabajaba, el apagado quedó pendiente.
        programarApagado()
    }

    private var esError: Bool { if case .error = estado { return true }; return false }

    // MARK: - Entorno

    /// El MCP de desarrollo de Nook, si el usuario lo tiene encendido. Es lo que le permite al
    /// agente manejar el propio navegador; sin el token, el servidor no está sirviendo.
    /// Se suman a las instrucciones de Claude Code en cada sesión del panel. Sin esto, para "¿de qué
    /// trata esta nota?" el agente buscaba en internet y descargaba la página con WebFetch (lento,
    /// sin la sesión del usuario, y se colgaba en sitios con muro de pago) en vez de leer la pestaña
    /// (Kurth, 24 sep, en robbreport.com).
    static let instrucciones = """
        Estás en el panel lateral de Nook, el navegador del usuario. Cada mensaje trae la pestaña \
        que está viendo: su dirección y, la primera vez que pregunta por ella, su contenido en \
        markdown (un resource). Cuando hable de "esta página", "esta nota" o "aquí", contesta \
        directo con ese contenido, que ya viene en <context>: no llames read_page para esa misma \
        dirección ni la busques en internet. Usa las herramientas del servidor MCP nook solo si \
        hace falta algo que no viene en el mensaje: read_page para leerla otra vez, snapshot para \
        ver qué se puede tocar, screenshot_tab para ver cómo se ve (diseño, imágenes, gráficas), y \
        click, type_text, press_key, hover, scroll y select_option para actuar; handle_dialog si \
        aparece un diálogo. Nunca uses WebFetch ni WebSearch para la página que ya tiene abierta. \
        Para trabajo que no deba interrumpirlo, abre tu propia pestaña con open_tab y ciérrala con \
        close_tab al terminar. Antes de publicar, comprar, borrar o enviar datos personales, \
        pregúntale. Sé breve.
        """

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
    /// El PATH del shell de inicio de sesión del usuario. Una app abierta desde el Finder recibe
    /// solo /usr/bin:/bin:/usr/sbin:/sbin: ahí `npx` no encuentra `node` ("env: node: No such file
    /// or directory", medido en la Air el 24 sep) y los MCP del usuario no encuentran uvx ni
    /// python. (En la Pro no se vio; no sé por qué: no lo verifiqué.)
    nonisolated private static func pathDeInicioDeSesion() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: shell)
        proceso.arguments = ["-lc", "printf %s \"$PATH\""]
        let salida = Pipe()
        proceso.standardOutput = salida
        proceso.standardError = FileHandle.nullDevice
        guard (try? proceso.run()) != nil else { return nil }
        proceso.waitUntilExit()
        let path = String(decoding: salida.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

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
