// Licensed under GPL-3.0. See LICENSE.
//
//  KurthMemorias.swift
//  Nook (rama kurth)
//
//  Memorias de Nook: lo que el navegador sabe de Kurth y su trabajo (la URL y el id de cada cuenta,
//  dónde está cada reporte, qué filtro usa, quién es quién), escrito por cualquier agente, por Kurth o
//  por un workflow. Es del navegador, no del agente: vive en Application Support de Nook y se lee y
//  escribe por el MCP de Nook, que es lo único común a Claude Code, Codex, Gemini o el que venga. Si
//  el agente tiene memoria propia (Claude Code con la suya), puede guardar también ahí: es "además de",
//  nunca "en vez de" (Kurth, 26 sep). Nook no lee ni escribe las memorias de ningún agente (~/.claude…).
//
//  Tres caminos:
//   1. Herramientas nook_memoria_buscar / guardar / listar / borrar (DevMCPServer vía KurthMCPTools).
//   2. Contexto automático: en cada mensaje del panel se agregan, ocultas, las que vienen al caso por
//      el texto y el host de la pestaña (KurthAgentService.enviar). Así "ve a la cuenta de Ultrafemme de
//      Google Ads" llega con la URL y el id aunque el agente no llame ninguna herramienta.
//   3. Workflows: al registrarse uno (KurthWorkflows.definir) se guarda qué sitios y cuentas usa.
//
//  Modelo, búsqueda y validación en KurthMemoriasModelo.swift (con prueba sin Nook).
//

import Foundation
import Observation
import NookWeb

@MainActor
@Observable
final class KurthMemorias {
    static let shared = KurthMemorias()

    static let ajuste = "kurth.memorias"
    static let ajusteAuto = "kurth.memoriasAuto"

    static var activas: Bool { UserDefaults.standard.object(forKey: ajuste) as? Bool ?? true }
    static var automaticas: Bool { activas && (UserDefaults.standard.object(forKey: ajusteAuto) as? Bool ?? true) }

    /// Todas, con las borradas que todavía viajan a las otras Macs.
    private(set) var memorias: [KurthMemoria] = []

    /// Las que se ven: vivas, lo más reciente arriba.
    var vivas: [KurthMemoria] {
        memorias.filter(\.viva).sorted { $0.actualizada > $1.actualizada }
    }

    @ObservationIgnored let tienda = KurthMemoriasTienda(archivo: KurthMemoriasTienda.archivoPorDefecto)
    /// Lo que ya se le mandó como contexto en esta sesión del agente (id → versión), para no repetirlo
    /// en cada mensaje. Una sesión nueva lo vacía.
    @ObservationIgnored private var enviadas: (sesion: String, versiones: [String: Date]) = ("", [:])

    private init() { recargar() }

    func recargar() {
        memorias = tienda.cargar()
        podarDeWorkflowsBorrados()
    }

    // MARK: - Cambios

    @discardableResult
    func guardar(_ entrada: KurthMemoriaEntrada) throws -> KurthMemoriasModelo.Resultado {
        var copia = memorias
        let resultado = try KurthMemoriasModelo.guardar(entrada, en: &copia)
        try tienda.guardar(copia)
        memorias = copia
        KurthSync.shared.programarExportacion()
        return resultado
    }

    @discardableResult
    func borrar(_ id: String) -> Bool {
        var copia = memorias
        guard KurthMemoriasModelo.borrar(id, en: &copia) else { return false }
        try? tienda.guardar(copia)
        memorias = copia
        KurthSync.shared.programarExportacion()
        return true
    }

    /// Cuenta un uso (se devolvió en una búsqueda o fue al contexto). Solo local: no viaja.
    private func usar(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let ahora = Date()
        for i in memorias.indices where ids.contains(memorias[i].id) {
            memorias[i].vecesUsada += 1
            memorias[i].ultimoUso = ahora
        }
        try? tienda.guardar(memorias)
    }

    // MARK: - Contexto automático

    /// El bloque oculto para un mensaje del panel: las (hasta 5) que vienen al caso por el texto y el
    /// host de la pestaña, sin las que ya se mandaron en esta sesión sin cambios. nil si no hay nada.
    func contextoParaMensaje(_ texto: String, url: URL?, sesion: String?) -> String? {
        guard Self.automaticas else { return nil }
        let clave = sesion ?? "sin-sesion"
        if enviadas.sesion != clave { enviadas = (clave, [:]) }
        let host = (url?.scheme == "https" || url?.scheme == "http") ? url?.host() : nil
        let elegidas = KurthMemoriasModelo.paraMensaje(memorias, texto: texto, host: host)
            .filter { enviadas.versiones[$0.id] != $0.actualizada }
        guard !elegidas.isEmpty else { return nil }
        for m in elegidas { enviadas.versiones[m.id] = m.actualizada }
        usar(elegidas.map(\.id))
        return KurthMemoriasModelo.contexto(elegidas)
    }

    // MARK: - Workflows

    /// Al registrarse un workflow (KurthWorkflows.definir), sus sitios y cuentas quedan como memoria de
    /// origen "workflow" con id wf-<nombre>: registrarlo otra vez la actualiza. Si Kurth la editó a mano
    /// ya es suya y no se pisa.
    func desdeWorkflow(_ wf: KurthWorkflow) {
        guard Self.activas else { return }
        if let existente = memorias.first(where: { $0.id == "wf-" + wf.nombre }), existente.viva, existente.origen == .kurth { return }
        let urls = wf.pasos.compactMap(\.url)
        guard let entrada = KurthMemoriasModelo.desdeWorkflow(nombre: wf.nombre, titulo: wf.titulo,
                                                               descripcion: wf.descripcion, urls: urls) else { return }
        try? guardar(entrada)
    }

    /// La memoria de un workflow que ya no existe se va (borrar o renombrar un workflow no tiene gancho
    /// aquí a propósito: un solo punto de llamada en KurthWorkflows, el de definir).
    private func podarDeWorkflowsBorrados() {
        let carpeta = KurthWorkflowsTienda.carpetaPorDefecto
        let huerfanas = memorias.filter { m in
            m.viva && m.origen == .workflow && m.id.hasPrefix("wf-")
                && !FileManager.default.fileExists(atPath: carpeta.appendingPathComponent(String(m.id.dropFirst(3)) + ".json").path)
        }
        guard !huerfanas.isEmpty else { return }
        var copia = memorias
        for m in huerfanas { KurthMemoriasModelo.borrar(m.id, en: &copia) }
        try? tienda.guardar(copia)
        memorias = copia
    }

    // MARK: - Otras Macs (KurthSync)

    func paraSincronizar() -> [KurthMemoria] {
        KurthMemoriasModelo.paraSincronizar(memorias)
    }

    func mezclarRemotas(_ remotas: [KurthMemoria]) {
        var copia = memorias
        guard KurthMemoriasModelo.mezclar(remotas, en: &copia) else { return }
        try? tienda.guardar(copia)
        memorias = copia
    }

    // MARK: - MCP

    /// Las descripciones enseñan el uso a cualquier agente, aunque no reciba las instrucciones del
    /// panel (Codex, Gemini o una sesión de Claude Code fuera de Nook con el MCP de Nook).
    static let herramientas: [AIToolDefinition] = [
        AIToolDefinition(
            name: "nook_memoria_buscar",
            description: """
            Memorias de Nook: lo que el navegador ya sabe de Kurth y su trabajo (URL e id de cada cuenta de Google Ads, \
            Meta, GA4, Merchant, etc. por marca; dónde está cada reporte; qué filtros usa; quién es quién). Son del \
            navegador, las comparten todos los agentes y proyectos. Búscalas ANTES de navegar a una cuenta, herramienta o \
            reporte, y antes de preguntarle a Kurth un dato que pudo quedar guardado. texto: palabras libres (marca, \
            herramienta, persona, id); host: el dominio o la URL de la pestaña (ads.google.com) para traer las de ese \
            sitio. Devuelve las más relevantes con su id. Si los mensajes del panel ya traen <memorias-de-nook>, esas \
            ya son el resultado de esta búsqueda.
            """,
            parameters: ["type": "object", "properties": [
                "texto": ["type": "string", "description": "Qué buscas, en palabras libres"],
                "host": ["type": "string", "description": "Dominio o URL para traer las de ese sitio"],
                "tipo": ["type": "string", "enum": KurthMemoria.Tipo.allCases.map(\.rawValue)],
                "etiqueta": ["type": "string", "description": "Marca o unidad: Ultrafemme, Krei, Luxury Avenue, Ultra Boutiques…"],
                "limite": ["type": "integer", "description": "Máximo de resultados (8 si no se dice)"],
            ]]
        ),
        AIToolDefinition(
            name: "nook_memoria_guardar",
            description: """
            Guarda en las memorias de Nook (las del navegador) algo reutilizable y estable que descubriste navegando: la \
            URL o el id de una cuenta, dónde está un reporte, un filtro o una preferencia de Kurth, una ruta dentro de una \
            herramienta, quién es quién. Todo lo que aprendas del navegador va SIEMPRE aquí, para que cualquier agente lo \
            tenga la próxima vez; si además tienes memoria propia, puedes guardarlo también ahí. Un hecho por memoria, \
            breve (una a tres líneas), en español. NUNCA contraseñas, tokens, llaves de API, códigos de verificación ni \
            números de tarjeta: se rechazan (guarda dónde vive la credencial, no su valor). Con id reemplaza esa memoria \
            (así se corrige lo que cambió); sin id, si ya existe una que es la misma, se le suma en vez de duplicarla. \
            tipo: cuenta | sitio | procedimiento | preferencia | persona | dato. hosts: dominios relacionados. etiquetas: \
            marca o unidad. origen: "kurth" solo si Kurth te dictó el dato para guardarlo.
            """,
            parameters: ["type": "object", "properties": [
                "id": ["type": "string", "description": "Para actualizar una existente (reemplaza su contenido)"],
                "titulo": ["type": "string", "description": "Corto: «Google Ads · Ultrafemme»"],
                "contenido": ["type": "string", "description": "Markdown breve con el dato"],
                "tipo": ["type": "string", "enum": KurthMemoria.Tipo.allCases.map(\.rawValue)],
                "hosts": ["type": "array", "items": ["type": "string"]],
                "etiquetas": ["type": "array", "items": ["type": "string"]],
                "origen": ["type": "string", "enum": ["agente", "kurth"]],
            ], "required": ["titulo", "contenido"]]
        ),
        AIToolDefinition(
            name: "nook_memoria_listar",
            description: "Lista las memorias de Nook, lo más reciente primero. Filtros opcionales: tipo, etiqueta (marca o unidad), host. Para buscar por relevancia usa nook_memoria_buscar.",
            parameters: ["type": "object", "properties": [
                "tipo": ["type": "string", "enum": KurthMemoria.Tipo.allCases.map(\.rawValue)],
                "etiqueta": ["type": "string"],
                "host": ["type": "string"],
                "limite": ["type": "integer", "description": "Máximo (50 si no se dice)"],
            ]]
        ),
        AIToolDefinition(
            name: "nook_memoria_borrar",
            description: "Borra una memoria de Nook por id (cuando ya no es cierta y no vale corregirla). Si solo cambió un dato, mejor nook_memoria_guardar con su id.",
            parameters: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]
        ),
    ]

    /// nil si la herramienta no es de memorias.
    static func llamar(_ nombre: String, _ args: [String: Any]) -> [String: Any]? {
        guard nombre.hasPrefix("nook_memoria_") else { return nil }
        let modelo = KurthMemoriasModelo.self
        let responder = KurthMCPTools.text
        guard activas else { return responder("Las memorias de Nook están apagadas (ajuste \(ajuste)).", true) }
        let s = shared
        let tipo = (args["tipo"] as? String).flatMap(KurthMemoria.Tipo.init(rawValue:))
        let etiqueta = (args["etiqueta"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let host = (args["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        switch nombre {
        case "nook_memoria_buscar":
            let limite = max(1, min((args["limite"] as? NSNumber)?.intValue ?? 8, 30))
            let q = (args["texto"] as? String) ?? ""
            guard !q.trimmingCharacters(in: .whitespaces).isEmpty || host != nil else {
                return responder("Pasa texto, host o los dos.", true)
            }
            let encontradas = modelo.buscar(s.memorias, texto: q, host: host, tipo: tipo, etiqueta: etiqueta).prefix(limite)
            s.usar(encontradas.map(\.memoria.id))
            guard !encontradas.isEmpty else {
                return responder("Ninguna memoria coincide. Si descubres el dato navegando, guárdalo con nook_memoria_guardar.", false)
            }
            return responder("\(encontradas.count) de \(s.vivas.count):\n" + encontradas.map { modelo.linea($0.memoria, maximo: 1500) }.joined(separator: "\n"), false)

        case "nook_memoria_guardar":
            var entrada = KurthMemoriaEntrada(
                id: args["id"] as? String,
                titulo: (args["titulo"] as? String) ?? "",
                contenido: (args["contenido"] as? String) ?? "",
                tipo: tipo,
                hosts: args["hosts"] as? [String],
                etiquetas: args["etiquetas"] as? [String])
            entrada.origen = (args["origen"] as? String) == "kurth" ? .kurth : .agente
            do {
                let r = try s.guardar(entrada)
                let que: String
                switch r {
                case .creada: que = "Guardada"
                case .actualizada: que = "Actualizada"
                case .fusionada: que = "Ya había una igual; se le sumó lo nuevo"
                }
                return responder("\(que): " + modelo.linea(r.memoria, maximo: 1500), false)
            } catch {
                return responder(error.localizedDescription, true)
            }

        case "nook_memoria_listar":
            let limite = max(1, min((args["limite"] as? NSNumber)?.intValue ?? 50, 200))
            let hostNormal = host.flatMap(modelo.host)
            let lista = s.vivas.filter { m in
                (tipo == nil || m.tipo == tipo)
                    && (etiqueta == nil || m.etiquetas.contains { modelo.normal($0) == modelo.normal(etiqueta!) })
                    && (hostNormal == nil || m.hosts.contains { $0 == hostNormal! || hostNormal!.hasSuffix("." + $0) })
            }
            guard !lista.isEmpty else { return responder("No hay memorias" + (tipo != nil || etiqueta != nil || host != nil ? " con ese filtro." : " todavía."), false) }
            return responder("\(lista.count) memorias:\n" + lista.prefix(limite).map { modelo.linea($0, maximo: 200) }.joined(separator: "\n"), false)

        case "nook_memoria_borrar":
            guard let id = args["id"] as? String, !id.isEmpty else { return responder("Falta id.", true) }
            guard let m = s.memorias.first(where: { $0.id == id && $0.viva }) else { return responder("No existe la memoria \(id).", true) }
            s.borrar(id)
            return responder("Borrada: «\(m.titulo)».", false)

        default:
            return responder("Herramientas: nook_memoria_buscar, nook_memoria_guardar, nook_memoria_listar, nook_memoria_borrar.", true)
        }
    }
}
