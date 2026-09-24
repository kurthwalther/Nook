// Licensed under GPL-3.0. See LICENSE.
//
//  KurthACPCheck.swift
//  Nook (rama kurth) — verificación, no se compila con la app.
//
//  Corre el cliente ACP de verdad contra el agente instalado y comprueba el camino entero:
//  arranque, sesión, respuesta en trozos, uso de herramienta, autorización y fin de turno.
//  Es el patrón de Checks/ que describe el CLAUDE.md del repo: se compila el archivo que sí
//  se envía, junto a este, y se ejecuta.
//
//      kurth/checks/correr.sh
//
//  Necesita el agente disponible (npx) y la sesión iniciada del usuario. Gasta un poco de su
//  cuota: dos turnos cortos.
//

import Foundation

/// El estado vive en una clase del actor principal a propósito: con variables locales
/// capturadas en los closures, el binario compilado con -O muere por acceso simultáneo a
/// memoria (SIGTRAP) antes de imprimir nada.
@MainActor
final class Registro {
    var chunks = ""
    var herramientas: [String] = []
    var permiso: KurthACPPermission?
    var finDeTurno: String?
}

@main
struct KurthACPCheck {
    static func main() async {
        // Sin esto, un fallo a media prueba se lleva por delante todo lo ya impreso: la salida
        // estándar se guarda en memoria hasta que se llena, y el diagnóstico se pierde justo
        // cuando hace falta.
        setbuf(stdout, nil)
        let npx = which("npx") ?? "/usr/local/bin/npx"
        let cliente = await KurthACPClient()
        let registro = await Registro()

        await MainActor.run {
            cliente.onEvent = { evento in
                switch evento {
                case .messageChunk(let t): registro.chunks += t
                case .toolStarted(_, let title, _): registro.herramientas.append(title)
                case .turnEnded(let r): registro.finDeTurno = r
                case .failed(let m): FileHandle.standardError.write(Data("‼️ \(m)\n".utf8))
                default: break
                }
            }
            cliente.onPermission = { permiso in
                registro.permiso = permiso
                return permiso.preferred?.id
            }
        }

        do {
            let t0 = Date()
            try await cliente.start(agent: .claudeCode(npx: npx))
            paso("arranca y negocia el protocolo", t0)

            let t1 = Date()
            try await cliente.newSession(cwd: URL(fileURLWithPath: NSTemporaryDirectory()))
            let sid = await cliente.sessionId
            precondition(sid != nil, "no hubo sessionId")
            let modos = await cliente.availableModes
            precondition(!modos.isEmpty, "la sesión no trajo modos")
            let modoActivo = await cliente.currentModeId
            paso("abre sesión (modo activo: \(modoActivo ?? "?") · disponibles: \(modos.map(\.name).joined(separator: ", ")))", t1)

            let t2 = Date()
            try await cliente.prompt("Responde unicamente con la palabra: listo")
            let texto = await registro.chunks
            let fin = await registro.finDeTurno
            precondition(texto.lowercased().contains("listo"), "no llegó la respuesta en trozos; llegó «\(texto)»")
            precondition(fin == "end_turn", "el turno no cerró bien: \(fin ?? "nada")")
            paso("responde en trozos y cierra el turno", t2)

            await MainActor.run { registro.chunks = ""; registro.finDeTurno = nil }
            let t3 = Date()
            // `echo` pasa sin preguntar: Claude Code lo trata como inofensivo. Para probar la
            // autorización hace falta un comando que sí la pida.
            try await cliente.prompt("Ejecuta en la terminal: sw_vers -productVersion. Dime solo el resultado.")
            let permiso = await registro.permiso
            let herramientas = await registro.herramientas
            let salida = await registro.chunks
            precondition(permiso != nil, "no pidió autorización para ejecutar")
            precondition(!herramientas.isEmpty, "no reportó ninguna herramienta")
            precondition(salida.contains("."), "no ejecutó el comando; llegó «\(salida)»")
            paso("pide autorización, la respeta y ejecuta", t3)
            print("   autorización para «\(permiso!.toolTitle)», \(permiso!.options.count) opciones; herramientas: \(herramientas)")

            await cliente.stop()
            print("\n✅ el cliente ACP funciona de punta a punta")
        } catch {
            await cliente.stop()
            FileHandle.standardError.write(Data("\n❌ falló: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func paso(_ nombre: String, _ desde: Date) {
        print(String(format: "✓ %@  (%.1f s)", nombre, Date().timeIntervalSince(desde)))
    }

    static func which(_ programa: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [programa]
        let salida = Pipe()
        p.standardOutput = salida
        try? p.run()
        p.waitUntilExit()
        let ruta = String(decoding: salida.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ruta.isEmpty ? nil : ruta
    }
}
