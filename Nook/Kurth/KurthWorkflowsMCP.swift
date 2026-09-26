// Licensed under GPL-3.0. See LICENSE.
//
//  KurthWorkflowsMCP.swift
//  Nook (rama kurth)
//
//  La herramienta kurth_workflow del MCP de Nook: todo lo del botón de Workflows sin mouse (para
//  probarlo con kurth/mcp.sh) y el camino con que el agente registra el skill que escribió (define).
//  Va por el camino async del servidor (gancho en DevMCPServer.callTool) porque terminar una
//  grabación espera a que la página suelte el último campo escrito.
//

import Foundation
import NookWeb

extension KurthWorkflows {
    static let herramienta = AIToolDefinition(
        name: "kurth_workflow",
        description: """
        Workflows grabados de Nook (botón junto al de captura en el panel del agente). action:
        start (graba las pestañas de la ventana activa; reemplaza: nombre para volver a grabar uno),
        stop (termina; con nombre guarda y pide el skill al agente, sin él deja a Kurth la tarjeta del nombre),
        discard, status (grabando, pasos, duración, último paso), note (texto: narración escrita),
        list, get (nombre: grabación legible y datos), run (nombre, parametros {clave: valor}),
        delete (nombre), define (lo usa el agente al terminar el SKILL.md: nombre, descripcion,
        parametros [{nombre, descripcion, ejemplo}]), schedule (nombre, regla {frecuencia: una-vez|diario|
        dias|cada-horas, fecha "AAAA-MM-DDTHH:MM" local, hora "HH:MM", dias ["lun","mié"], cadaHoras},
        parametros), unschedule (nombre), runs (nombre: historial de corridas).
        """,
        parameters: ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["start", "stop", "discard", "status", "note", "list", "get", "run",
                                                  "delete", "define", "schedule", "unschedule", "runs"]],
            "nombre": ["type": "string", "description": "Nombre corto del workflow (o, en stop, el nombre a guardar)"],
            "descripcion": ["type": "string"],
            "texto": ["type": "string", "description": "note: lo que se agrega como narración"],
            "reemplaza": ["type": "string", "description": "start: nombre del workflow que se vuelve a grabar"],
            "parametros": ["description": "run/schedule: {clave: valor}. define: [{nombre, descripcion, ejemplo}]"],
            "regla": ["type": "object"],
        ], "required": ["action"]]
    )

    /// nil si no es kurth_workflow.
    static func llamar(_ nombre: String, _ args: [String: Any], browserManager bm: BrowserManager,
                       window: BrowserWindowState) async -> [String: Any]? {
        guard nombre == herramienta.name else { return nil }
        let w = shared
        let texto = KurthMCPTools.text
        let json = KurthMCPTools.json
        let n = (args["nombre"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        w.browserManager = w.browserManager ?? bm
        do {
            switch args["action"] as? String {
            case "start":
                try w.empezar(en: window, tabs: bm.tabs, reemplaza: (args["reemplaza"] as? String).flatMap { $0.isEmpty ? nil : $0 })
                return texto(json(w.estado()), false)
            case "stop":
                await w.terminar()
                guard !n.isEmpty else {
                    return texto("Grabación detenida; Nook pide el nombre sobre la página. Pasa nombre para guardar sin preguntar.\n" + json(w.estado()), false)
                }
                let wf = try w.guardar(titulo: n, descripcion: args["descripcion"] as? String ?? "")
                return texto("Guardado «\(wf.nombre)» en \(w.tienda.ruta(wf.nombre).path) con \(wf.acciones) acciones; se le pidió el skill al agente.\n\n"
                             + KurthWorkflowsModelo.markdown(wf), false)
            case "discard":
                guard w.grabacion != nil else { throw Problema.noGrabando }
                w.descartar()
                return texto("Descartada.", false)
            case "status":
                return texto(json(w.estado()), false)
            case "note":
                guard w.grabacion?.fase == .grabando else { throw Problema.noGrabando }
                let t = (args["texto"] as? String) ?? ""
                w.anotar(t)
                return texto(json(w.estado()), false)
            case "list":
                let filas = w.workflows.map { wf -> [String: Any] in
                    var fila: [String: Any] = ["nombre": wf.nombre, "titulo": wf.titulo, "descripcion": wf.descripcion,
                                               "acciones": wf.acciones, "skillAlDia": wf.skillAlDia,
                                               "parametros": wf.parametros.map(\.nombre),
                                               "actualizado": ISO8601DateFormatter().string(from: wf.actualizado)]
                    if let p = wf.programacion {
                        fila["programacion"] = KurthWorkflowsModelo.describir(p) + (p.activa ? "" : " (inactiva)")
                        if let d = p.proxima { fila["proxima"] = KurthWorkflowsModelo.cuando(d) }
                        if let d = p.saltada { fila["saltada"] = KurthWorkflowsModelo.cuando(d) }
                    }
                    return fila
                }
                return texto(json(["programadosActivos": programadosActivos, "carpeta": w.tienda.carpeta.path, "workflows": filas]), false)
            case "get":
                guard let wf = w.tienda.cargar(n) else { throw Problema.noExiste(n) }
                var salida = "Archivo: \(w.tienda.ruta(n).path)\nSkill: " + (w.textoDelSkill(n) == nil ? "todavía no existe" : "~/.claude/skills/\(n)/SKILL.md")
                    + (wf.skillAlDia ? " (al día)" : " (sin registrar esta versión)")
                if !wf.parametros.isEmpty {
                    salida += "\nParámetros: " + wf.parametros.map { "\($0.nombre) = «\(wf.valorInicial($0))»" }.joined(separator: ", ")
                }
                return texto(salida + "\n\n" + KurthWorkflowsModelo.markdown(wf), false)
            case "run":
                let valores = (args["parametros"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
                try w.correr(n, valores: valores, programada: false)
                return texto("Mandado al agente: «\(n)». El resultado queda en runs cuando termine.", false)
            case "delete":
                try w.borrar(n)
                return texto("Borrado «\(n)»; se le pidió al agente quitar su skill.", false)
            case "define":
                let lista = (args["parametros"] as? [[String: Any]])?.map {
                    KurthWorkflowParametro(nombre: KurthWorkflows.claveDeParametro($0["nombre"] as? String ?? ""),
                                           descripcion: $0["descripcion"] as? String ?? "",
                                           ejemplo: "\($0["ejemplo"] ?? "")")
                }
                let wf = try w.definir(n, descripcion: args["descripcion"] as? String, parametros: lista)
                return texto("Registrado «\(wf.titulo)»: \(wf.parametros.count) parámetros. Ya aparece en Workflows.", false)
            case "schedule":
                guard let regla = args["regla"] as? [String: Any] else { throw KurthWorkflowsModelo.ErrorDeRegla("Falta regla") }
                var p = try KurthWorkflowsModelo.programacion(desde: regla)
                p.valores = (args["parametros"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
                try w.programar(n, p)
                let guardada = w.tienda.cargar(n)?.programacion
                return texto("Programado: \(KurthWorkflowsModelo.describir(p)). Próxima: "
                             + (guardada?.proxima.map { KurthWorkflowsModelo.cuando($0) } ?? "ninguna (ya pasó)")
                             + (programadosActivos ? "" : ". Ojo: kurth.workflowsProgramados está en false."), false)
            case "unschedule":
                try w.desprogramar(n)
                return texto("Sin programación: «\(n)».", false)
            case "runs":
                guard let wf = w.tienda.cargar(n) else { throw Problema.noExiste(n) }
                let f = ISO8601DateFormatter()
                let filas = wf.corridas.reversed().map { c -> [String: Any] in
                    var fila: [String: Any] = ["inicio": f.string(from: c.inicio), "estado": c.estado.rawValue,
                                               "programada": c.programada, "resumen": c.resumen ?? ""]
                    if let fin = c.fin { fila["duracion"] = KurthWorkflowsModelo.minutos(fin.timeIntervalSince(c.inicio)) }
                    return fila
                }
                return texto(json(filas), false)
            default:
                return texto("action: start, stop, discard, status, note, list, get, run, delete, define, schedule, unschedule o runs", true)
            }
        } catch {
            return texto(error.localizedDescription, true)
        }
    }

    /// Para kurth_workflow status y para que José vea que se está captando.
    func estado() -> [String: Any] {
        guard let g = grabacion else { return ["grabando": false] }
        var e: [String: Any] = [
            "grabando": g.fase == .grabando,
            "fase": g.fase == .grabando ? "grabando" : "esperando nombre",
            "pasos": g.acciones,
            "narracion": g.frases,
            "duracion": KurthWorkflowsModelo.minutos(g.duracion()),
            "microfono": voz.encendida,
        ]
        if let error = voz.error { e["errorDelMicrofono"] = error }
        if let ultimo = g.pasos.last { e["ultimoPaso"] = KurthWorkflowsModelo.linea(ultimo) }
        if let r = g.reemplaza { e["reemplaza"] = r }
        return e
    }

    /// minúsculas_con_guiones_bajos, como pide el skill.
    static func claveDeParametro(_ crudo: String) -> String {
        KurthGuardarSkill.nombreValido(crudo).replacingOccurrences(of: "-", with: "_")
    }
}
