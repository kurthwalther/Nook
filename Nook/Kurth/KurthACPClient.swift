// Licensed under GPL-3.0. See LICENSE.
//
//  KurthACPClient.swift
//  Nook (rama kurth)
//
//  Cliente del Agent Client Protocol (ACP), el estándar de Zed para hablar con agentes de
//  código. Sirve para que el chat de Nook corra sobre el agente que el usuario ya tiene
//  instalado y pagado —su suscripción, sus memorias, sus skills, sus plugins, sus hooks y sus
//  MCP— en vez de contra una API con su propia llave.
//
//  Cómo funciona el transporte: se lanza el agente como subproceso y se le mandan mensajes
//  JSON-RPC 2.0 por su entrada estándar, uno por línea, en UTF-8; él contesta igual por su
//  salida estándar. No hay red de por medio ni servidor que levantar. La salida de error del
//  subproceso es texto suelto de diagnóstico, no JSON, y se entrega aparte.
//
//  Lo medido en la Pro el 2026-09-23 contra @agentclientprotocol/claude-agent-acp 0.81.1:
//  `initialize` ~1 s, `session/new` 8.5–9 s (por eso la sesión se abre al abrir la pestaña del
//  agente y no al primer mensaje), y una respuesta corta 1.5–2 s. La autenticación sale del
//  login que ya tiene el agente: contestó plan=max sin ANTHROPIC_API_KEY en el entorno.
//
//  Sobre no reusar StdioTransport (Nook/Managers/AIManager/MCP/MCPTransport.swift): ahí ya hay
//  un transporte por stdio con JSON-RPC por líneas, y se miró antes de escribir este. Se dejó
//  aparte por dos razones concretas: manda la salida de error a /dev/null, y aquí es donde el
//  adaptador reporta en qué fase va cuando algo tarda o falla; y está tipado contra
//  MCPTransportProtocol, que es un archivo de upstream y tocarlo genera conflictos en cada
//  rebase. De ahí sí se copiaron sus dos protecciones: validar el ejecutable antes de lanzarlo
//  y poner tope al tamaño de un mensaje.
//
//  Quién ejecuta las herramientas: el agente, no Nook. Eso es lo que separa a ACP de un
//  proveedor de API, donde la app recibe la llamada y la ejecuta. Aquí Nook solo decide, porque
//  el agente pide autorización con `session/request_permission` y espera la respuesta. Por eso
//  `onPermission` no es opcional: si nadie contesta, el agente se queda esperando.
//

import Foundation

// MARK: - JSON sin esquema

/// Un valor JSON cualquiera. ACP tiene mucha superficie y crece; en vez de modelar todo el
/// esquema se tipa a mano lo que Nook usa y el resto viaja íntegro aquí.
indirect enum KurthJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([KurthJSON])
    case object([String: KurthJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([KurthJSON].self) { self = .array(v) }
        else if let v = try? c.decode([String: KurthJSON].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "valor JSON no reconocido")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // Accesos cómodos: devuelven nil en vez de reventar, porque esto viene de otro proceso.
    subscript(key: String) -> KurthJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [KurthJSON]? { if case .array(let a) = self { return a }; return nil }

    static func from(_ any: Any) -> KurthJSON {
        switch any {
        case is NSNull: return .null
        case let v as Bool: return .bool(v)
        case let v as Int: return .number(Double(v))
        case let v as Double: return .number(v)
        case let v as String: return .string(v)
        case let v as [Any]: return .array(v.map(KurthJSON.from))
        case let v as [String: Any]: return .object(v.mapValues(KurthJSON.from))
        default: return .null
        }
    }
}

// MARK: - Lo que el cliente entrega hacia arriba

/// Lo que va pasando durante un turno. Llega en el hilo principal.
enum KurthACPEvent: Sendable {
    /// Un pedazo de la respuesta del agente (llega en trozos, como al escribir).
    case messageChunk(String)
    /// Un pedazo del razonamiento, cuando el agente lo publica.
    case thoughtChunk(String)
    /// El agente empezó a usar una herramienta.
    case toolStarted(id: String, title: String, kind: String)
    /// Esa herramienta cambió de estado ("pending", "in_progress", "completed", "failed").
    case toolUpdated(id: String, status: String)
    /// El plan de trabajo que el agente publica y va actualizando.
    case plan([String])
    /// Los comandos que el agente ofrece («/model», «/context», y cada skill del usuario).
    /// Llegan poco después de abrir la sesión, no en la respuesta de session/new.
    case commands([KurthACPCommand])
    /// Diagnóstico del subproceso (su salida de error). No es parte del protocolo.
    case diagnostic(String)
    /// El agente terminó el turno. `stopReason` suele ser "end_turn", "cancelled" o "refusal".
    case turnEnded(stopReason: String)
    /// Se murió el subproceso o el protocolo se rompió.
    case failed(String)
    /// Cambiaron las opciones de la sesión (modelo, esfuerzo, modo, rápido).
    case configChanged([KurthACPConfigOption])
}

/// Una opción de la sesión que el agente deja cambiar: claude-agent-acp publica "mode", "model",
/// "effort" y "fast" en `configOptions` de session/new, y se cambian con
/// session/set_config_option. Así se ven y se eligen como en el CLI (/model, /effort).
struct KurthACPConfigOption: Sendable, Identifiable, Equatable {
    struct Choice: Sendable, Identifiable, Equatable {
        let value: String
        let name: String
        var id: String { value }
    }
    let id: String
    let name: String
    var currentValue: String
    let choices: [Choice]

    var currentName: String { choices.first(where: { $0.value == currentValue })?.name ?? currentValue }

    static func parse(_ json: KurthJSON?) -> [KurthACPConfigOption] {
        (json?.arrayValue ?? []).compactMap { o in
            guard let id = o["id"]?.stringValue, let current = o["currentValue"]?.stringValue else { return nil }
            let choices = (o["options"]?.arrayValue ?? []).compactMap { c -> Choice? in
                guard let value = c["value"]?.stringValue else { return nil }
                return Choice(value: value, name: c["name"]?.stringValue ?? value)
            }
            return KurthACPConfigOption(id: id, name: o["name"]?.stringValue ?? id, currentValue: current, choices: choices)
        }
    }
}

/// Un enlace que acompaña al mensaje (ACP `resource_link`): el agente sabe de qué se habla sin
/// que se le mande el contenido. Nook lo usa para decirle qué pestaña está viendo el usuario;
/// probado el 24 sep: "¿qué página estoy viendo?" → "Spotify Web Player (open.spotify.com)".
struct KurthACPResourceLink: Sendable {
    let uri: String
    let name: String
    var title: String?

    var payload: KurthJSON {
        var campos: [String: KurthJSON] = ["type": .string("resource_link"), "uri": .string(uri), "name": .string(name)]
        if let title { campos["title"] = .string(title) }
        return .object(campos)
    }
}

/// Un comando de los que el agente publica. Se manda como texto del prompt, tal cual.
struct KurthACPCommand: Sendable, Identifiable, Equatable {
    var name: String
    var description: String
    var id: String { name }
}

/// Una autorización que el agente pide antes de actuar.
struct KurthACPPermission: Sendable {
    struct Option: Sendable, Identifiable {
        let id: String
        let name: String
        /// "allow_once", "allow_always", "reject_once", "reject_always".
        let kind: String
    }
    let toolTitle: String
    let toolKind: String
    let options: [Option]

    /// La opción que conviene resaltar: permitir sólo esta vez.
    var preferred: Option? {
        options.first { $0.kind == "allow_once" } ?? options.first
    }
}

/// Cómo se lanza un agente. El comando es el ejecutable, tal cual, con sus argumentos.
struct KurthACPAgent: Sendable, Equatable {
    var name: String
    var command: String
    var arguments: [String]
    var environment: [String: String] = [:]

    /// Claude Code por el adaptador de Zed. Se resuelve con `npx` para no obligar a instalarlo.
    static func claudeCode(npx: String) -> KurthACPAgent {
        KurthACPAgent(name: "Claude Code",
                      command: npx,
                      arguments: ["-y", "@agentclientprotocol/claude-agent-acp"])
    }
}

/// Un servidor MCP que Nook le presta al agente. Los pone el cliente, no el agente: así el
/// agente puede manejar el propio navegador con el Browser Control de Nook.
struct KurthACPMCPServer: Sendable {
    var name: String
    var url: URL
    var headers: [(name: String, value: String)]

    var payload: KurthJSON {
        .object([
            "type": .string("http"),
            "name": .string(name),
            "url": .string(url.absoluteString),
            "headers": .array(headers.map { .object(["name": .string($0.name), "value": .string($0.value)]) }),
        ])
    }
}

enum KurthACPError: LocalizedError {
    case notRunning
    case agentError(code: Int, message: String)
    case badResponse(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "El agente no está corriendo."
        case .agentError(let code, let message): return "El agente respondió con error \(code): \(message)"
        case .badResponse(let what): return "Respuesta que no se entiende: \(what)"
        case .timedOut(let what): return "El agente no respondió a tiempo: \(what)"
        }
    }
}

// MARK: - El cliente

@MainActor
final class KurthACPClient {
    /// Se llama con cada evento del turno, siempre en el hilo principal.
    var onEvent: ((KurthACPEvent) -> Void)?
    /// Se llama cuando el agente pide autorización. Hay que contestar o el turno se queda
    /// detenido: devolver el `id` de la opción elegida, o nil para cancelar.
    var onPermission: ((KurthACPPermission) async -> String?)?

    private(set) var sessionId: String?
    private(set) var isRunning = false
    /// Modos que ofrece la sesión ("default" manual, "acceptEdits", "plan") y el activo.
    private(set) var availableModes: [(id: String, name: String)] = []
    private(set) var currentModeId: String?
    private(set) var configOptions: [KurthACPConfigOption] = []

    private var process: Process?
    private var toAgent: FileHandle?
    private var pendingRequests: [Int: CheckedContinuation<KurthJSON, Error>] = [:]
    private var nextId = 1
    private var buffer = Data()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Tope para un solo mensaje, el mismo que usa el transporte de MCP. Sin esto, un agente
    /// que escupa basura sin saltos de línea hace crecer el buffer hasta llenar la memoria.
    private static let maxMessageSize = 10 * 1024 * 1024

    // MARK: Ciclo de vida

    /// Lanza el agente y negocia el protocolo. No abre sesión todavía.
    func start(agent: KurthACPAgent) async throws {
        stop()

        // Se valida antes de lanzar, como hace el transporte de MCP: si la ruta no existe o no
        // es ejecutable, Process lanza una excepción de Objective-C que no se puede atrapar.
        let fm = FileManager.default
        guard fm.fileExists(atPath: agent.command), fm.isExecutableFile(atPath: agent.command) else {
            throw KurthACPError.badResponse("el agente «\(agent.name)» no es ejecutable en \(agent.command)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: agent.command)
        process.arguments = agent.arguments
        var environment = ProcessInfo.processInfo.environment
        agent.environment.forEach { environment[$0.key] = $0.value }
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.onEvent?(.diagnostic(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in self?.handleTermination(status: proc.terminationStatus) }
        }

        try process.run()
        self.process = process
        self.toAgent = input.fileHandleForWriting
        self.isRunning = true

        // Las capacidades de archivo van en false a propósito: que el agente lea y escriba con
        // sus propias herramientas, que ya pasan por el permiso del usuario. Delegarlas a Nook
        // añadiría un camino de escritura en disco sin ese freno.
        _ = try await request("initialize", params: .object([
            "protocolVersion": .number(1),
            "clientCapabilities": .object([
                "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]),
                "terminal": .bool(true),
            ]),
        ]), timeout: 60)
    }

    /// Abre la conversación. Tarda varios segundos: conviene llamarla al abrir la pestaña del
    /// agente, no al mandar el primer mensaje.
    func newSession(cwd: URL, mcpServers: [KurthACPMCPServer] = []) async throws {
        let result = try await request("session/new", params: .object([
            "cwd": .string(cwd.path),
            "mcpServers": .array(mcpServers.map(\.payload)),
        ]), timeout: 120)

        guard let id = result["sessionId"]?.stringValue else {
            throw KurthACPError.badResponse("session/new sin sessionId")
        }
        sessionId = id
        leerModos(result)
    }

    /// Retoma en un proceso nuevo del agente una conversación que ya existía, sin repetirla
    /// (`session/resume`; claude-agent-acp la anuncia en `sessionCapabilities.resume`). Probado
    /// el 24 sep: 3.8 s, cero mensajes repetidos y el agente conserva el contexto.
    func resumeSession(_ id: String, cwd: URL, mcpServers: [KurthACPMCPServer] = []) async throws {
        let result = try await request("session/resume", params: .object([
            "sessionId": .string(id),
            "cwd": .string(cwd.path),
            "mcpServers": .array(mcpServers.map(\.payload)),
        ]), timeout: 120)
        sessionId = id
        leerModos(result)
    }

    /// Cambia una opción de la sesión (p. ej. "model" → "sonnet", "effort" → "high").
    func setConfigOption(_ id: String, value: String) async throws {
        guard let sessionId else { throw KurthACPError.notRunning }
        let result = try await request("session/set_config_option", params: .object([
            "sessionId": .string(sessionId),
            "configId": .string(id),
            "value": .string(value),
        ]), timeout: 30)
        let nuevas = KurthACPConfigOption.parse(result["configOptions"])
        if !nuevas.isEmpty {
            configOptions = nuevas
        } else if let i = configOptions.firstIndex(where: { $0.id == id }) {
            configOptions[i].currentValue = value
        }
        if id == "mode" { currentModeId = value }
        onEvent?(.configChanged(configOptions))
    }

    private func leerModos(_ result: KurthJSON) {
        let opciones = KurthACPConfigOption.parse(result["configOptions"])
        if !opciones.isEmpty { configOptions = opciones }
        currentModeId = result["modes"]?["currentModeId"]?.stringValue
        availableModes = (result["modes"]?["availableModes"]?.arrayValue ?? []).compactMap {
            guard let id = $0["id"]?.stringValue, let name = $0["name"]?.stringValue else { return nil }
            return (id, name)
        }
    }

    /// Manda un mensaje y espera a que el agente termine el turno. Las respuestas parciales van
    /// llegando por `onEvent`.
    @discardableResult
    func prompt(_ text: String, links: [KurthACPResourceLink] = []) async throws -> String {
        guard let sessionId else { throw KurthACPError.notRunning }
        let result = try await request("session/prompt", params: .object([
            "sessionId": .string(sessionId),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])] + links.map(\.payload)),
        ]), timeout: 3600)
        let reason = result["stopReason"]?.stringValue ?? "end_turn"
        onEvent?(.turnEnded(stopReason: reason))
        return reason
    }

    /// Interrumpe el turno en curso sin cerrar la sesión.
    func cancel() {
        guard let sessionId else { return }
        notify("session/cancel", params: .object(["sessionId": .string(sessionId)]))
    }

    func stop() {
        process?.terminationHandler = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        toAgent = nil
        sessionId = nil
        isRunning = false
        failPending(KurthACPError.notRunning)
    }

    // MARK: Envío

    private func request(_ method: String, params: KurthJSON, timeout: TimeInterval) async throws -> KurthJSON {
        guard isRunning else { throw KurthACPError.notRunning }
        let id = nextId
        nextId += 1

        send(.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ]))

        // El reloj corre aparte: si el agente se cuelga, la interfaz no se queda esperando para
        // siempre. Al vencer se descarta la continuación para que una respuesta tardía no
        // reanude dos veces, que es un fallo duro en Swift.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, let pending = self.pendingRequests.removeValue(forKey: id) else { return }
                pending.resume(throwing: KurthACPError.timedOut(method))
            }
        }
        defer { watchdog.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
        }
    }

    private func notify(_ method: String, params: KurthJSON) {
        send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }

    private func respond(id: KurthJSON, result: KurthJSON) {
        send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func send(_ message: KurthJSON) {
        guard let toAgent, var data = try? encoder.encode(message) else { return }
        data.append(0x0A) // una línea por mensaje, como pide el transporte
        do {
            try toAgent.write(contentsOf: data)
        } catch {
            onEvent?(.failed("No se pudo escribirle al agente: \(error.localizedDescription)"))
        }
    }

    // MARK: Recepción

    private func receive(_ data: Data) {
        buffer.append(data)
        if buffer.count > Self.maxMessageSize {
            buffer.removeAll(keepingCapacity: false)
            onEvent?(.failed("El agente mandó un mensaje demasiado grande; se descartó."))
            return
        }
        while let salto = buffer.firstIndex(of: 0x0A) {
            let linea = buffer[buffer.startIndex..<salto]
            buffer = buffer[buffer.index(after: salto)...]
            guard !linea.isEmpty, let mensaje = try? decoder.decode(KurthJSON.self, from: Data(linea)) else { continue }
            handle(mensaje)
        }
    }

    private func handle(_ message: KurthJSON) {
        // Respuesta a algo que pedimos.
        if let idValue = message["id"], let id = idValue.doubleValue.map(Int.init) {
            if let method = message["method"]?.stringValue {
                handleServerRequest(method: method, id: idValue, params: message["params"] ?? .null)
                return
            }
            guard let pending = pendingRequests.removeValue(forKey: id) else { return }
            if let error = message["error"] {
                let code = Int(error["code"]?.doubleValue ?? -1)
                let text = error["message"]?.stringValue ?? "sin detalle"
                pending.resume(throwing: KurthACPError.agentError(code: code, message: text))
            } else {
                pending.resume(returning: message["result"] ?? .null)
            }
            return
        }
        // Notificación del agente.
        if let method = message["method"]?.stringValue {
            handleNotification(method: method, params: message["params"] ?? .null)
        }
    }

    private func handleNotification(method: String, params: KurthJSON) {
        guard method == "session/update", let update = params["update"] else { return }
        switch update["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            if let text = update["content"]?["text"]?.stringValue { onEvent?(.messageChunk(text)) }
        case "agent_thought_chunk":
            if let text = update["content"]?["text"]?.stringValue { onEvent?(.thoughtChunk(text)) }
        case "tool_call":
            onEvent?(.toolStarted(id: update["toolCallId"]?.stringValue ?? "",
                                  title: update["title"]?.stringValue ?? "herramienta",
                                  kind: update["kind"]?.stringValue ?? "other"))
        case "tool_call_update":
            onEvent?(.toolUpdated(id: update["toolCallId"]?.stringValue ?? "",
                                  status: update["status"]?.stringValue ?? "unknown"))
        case "available_commands_update":
            let comandos = (update["availableCommands"]?.arrayValue ?? []).compactMap { c -> KurthACPCommand? in
                guard let name = c["name"]?.stringValue else { return nil }
                return KurthACPCommand(name: name, description: c["description"]?.stringValue ?? "")
            }
            if !comandos.isEmpty { onEvent?(.commands(comandos)) }
        case "plan":
            let pasos = (update["entries"]?.arrayValue ?? []).compactMap { $0["content"]?.stringValue }
            if !pasos.isEmpty { onEvent?(.plan(pasos)) }
        case "config_option_update":
            let opciones = KurthACPConfigOption.parse(update["configOptions"])
            if !opciones.isEmpty { configOptions = opciones; onEvent?(.configChanged(opciones)) }
        case "current_mode_update":
            if let modo = update["currentModeId"]?.stringValue {
                currentModeId = modo
                if let i = configOptions.firstIndex(where: { $0.id == "mode" }) { configOptions[i].currentValue = modo }
                onEvent?(.configChanged(configOptions))
            }
        default:
            break
        }
    }

    /// El agente también nos pide cosas a nosotros. Hoy sólo la autorización de herramientas.
    private func handleServerRequest(method: String, id: KurthJSON, params: KurthJSON) {
        guard method == "session/request_permission" else {
            respond(id: id, result: .object([:]))
            return
        }
        let call = params["toolCall"] ?? .null
        let permission = KurthACPPermission(
            toolTitle: call["title"]?.stringValue ?? "una acción",
            toolKind: call["kind"]?.stringValue ?? "other",
            options: (params["options"]?.arrayValue ?? []).compactMap {
                guard let id = $0["optionId"]?.stringValue else { return nil }
                return KurthACPPermission.Option(id: id,
                                                 name: $0["name"]?.stringValue ?? id,
                                                 kind: $0["kind"]?.stringValue ?? "allow_once")
            })

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Sin nadie que decida, se rechaza: es lo seguro en un navegador, donde la página
            // que el agente está leyendo puede traer instrucciones de quien la escribió.
            guard let onPermission = self.onPermission, let chosen = await onPermission(permission) else {
                self.respond(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
                return
            }
            self.respond(id: id, result: .object([
                "outcome": .object(["outcome": .string("selected"), "optionId": .string(chosen)]),
            ]))
        }
    }

    // MARK: Caídas

    private func handleTermination(status: Int32) {
        isRunning = false
        sessionId = nil
        failPending(KurthACPError.notRunning)
        onEvent?(.failed("El agente terminó con código \(status)."))
    }

    private func failPending(_ error: Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        pending.values.forEach { $0.resume(throwing: error) }
    }
}
