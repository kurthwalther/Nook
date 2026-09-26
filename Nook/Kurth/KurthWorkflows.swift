// Licensed under GPL-3.0. See LICENSE.
//
//  KurthWorkflows.swift
//  Nook (rama kurth)
//
//  Workflows grabados (Kurth, 26 sep): "grabar workflow, ve los clics, ve cómo hago, y después el
//  agente lo repite cuando quiera", desde un botón propio junto al de captura, sin escribir «/».
//
//  Cómo funciona:
//   · Grabar: KurthGrabadora.js (mundo aislado "KurthGrabadora") manda cada clic, campo, lista,
//     tecla y scroll grande de las pestañas de la ventana; aquí se suman las direcciones y las
//     pestañas (abrir, cerrar, cambiar), que la página no ve. Lo que Kurth dice (KurthWorkflowsVoz,
//     en el dispositivo) y lo que escribe en la caja del agente mientras graba queda intercalado.
//   · Guardar: Nook escribe la grabación en Application Support/…/Kurth/workflows/<nombre>.json (la
//     fuente de verdad de la lista) y le pide al agente del panel que escriba el skill en
//     ~/.claude/skills/<nombre>/SKILL.md con sus herramientas y permisos (Nook no escribe en
//     ~/.claude). El agente lo registra de vuelta con kurth_workflow define: descripción y parámetros.
//   · Ejecutar (popover, MCP o programador, KurthWorkflowsProgramador.swift): desde el 26 sep, Nook
//     repite los pasos del JSON sin LLM (KurthWorkflowsReplay.swift) y el agente solo resuelve el paso
//     que no aparezca. Un workflow sin pasos que repetir (solo narración) sigue yendo completo al
//     agente, que cierra con una línea «Resultado: …» que se guarda como corrida.
//  Ajuste kurth.workflows (false = sin botón ni grabador en páginas nuevas).
//

import AppKit
import Foundation
import Observation
import SwiftUI
import WebKit
import NookBlocker
import NookWeb
import os

@MainActor
@Observable
final class KurthWorkflows {
    static let shared = KurthWorkflows()

    static let ajuste = "kurth.workflows"
    static let ajusteVoz = "kurth.workflowsVoz"
    static let ajusteProgramados = "kurth.workflowsProgramados"
    static var activo: Bool { UserDefaults.standard.object(forKey: ajuste) as? Bool ?? true }
    static var vozAlEmpezar: Bool { UserDefaults.standard.object(forKey: ajusteVoz) as? Bool ?? true }
    static var programadosActivos: Bool { UserDefaults.standard.object(forKey: ajusteProgramados) as? Bool ?? true }

    @ObservationIgnored static let log = Logger(subsystem: "com.nook.browser", category: "KurthWorkflows")

    @ObservationIgnored let tienda = KurthWorkflowsTienda(carpeta: KurthWorkflowsTienda.carpetaPorDefecto)
    /// Lo que enseña el popover, leído de los JSON.
    private(set) var workflows: [KurthWorkflow] = []
    let voz = KurthWorkflowsVoz()

    // MARK: - Estado de la grabación

    enum Fase: Equatable { case grabando, nombrando }

    struct Grabacion: Equatable {
        let ventana: UUID
        let inicio: Date
        let reemplaza: String?
        var pasos: [KurthWorkflowPaso] = []
        var fase: Fase = .grabando
        var terminada: Date?

        var acciones: Int { pasos.filter { !$0.esNarracion }.count }
        var frases: Int { pasos.filter(\.esNarracion).count }
        func duracion(_ ahora: Date = Date()) -> Double { (terminada ?? ahora).timeIntervalSince(inicio) }
        func t(_ fecha: Date = Date()) -> Double { max(0, fecha.timeIntervalSince(inicio)) }
    }

    private(set) var grabacion: Grabacion?

    func grabandoEn(_ ventana: UUID) -> Bool { grabacion?.ventana == ventana && grabacion?.fase == .grabando }

    @ObservationIgnored weak var browserManager: BrowserManager?
    @ObservationIgnored private weak var tabs: TabsController?
    @ObservationIgnored private weak var ventana: BrowserWindowState?
    @ObservationIgnored private var fotoAnterior: Foto?
    /// Pestañas abiertas durante la grabación: su primera dirección sí cuenta como paso.
    @ObservationIgnored private var pestañasNuevas = Set<UUID>()
    /// El temporizador de lo programado (KurthWorkflowsProgramador.swift).
    @ObservationIgnored var temporizador: Task<Void, Never>?
    @ObservationIgnored var observadoresDelSistema: [NSObjectProtocol] = []

    private init() {
        voz.alFragmento = { [weak self] texto, fecha in self?.narrar(.voz, texto, en: fecha) }
        recargar()
    }

    /// Al abrir Nook (gancho en NookApp): el navegador para abrir el panel y el programador.
    func arrancar(browserManager bm: BrowserManager) {
        browserManager = bm
        arrancarProgramador()
    }

    func recargar() { workflows = tienda.todos() }

    func workflow(_ nombre: String) -> KurthWorkflow? { workflows.first { $0.nombre == nombre } ?? tienda.cargar(nombre) }

    // MARK: - Instalación del grabador en cada vista web

    static let mundo = WKContentWorld.world(name: "KurthGrabadora")
    private static let fuente: String? = {
        guard let ruta = Bundle.main.path(forResource: "KurthGrabadora", ofType: "js"),
              let js = try? String(contentsOfFile: ruta, encoding: .utf8), !js.isEmpty else { return nil }
        return js
    }()

    @ObservationIgnored private let controladores = NSHashTable<WKUserContentController>.weakObjects()
    @ObservationIgnored private let vistas = NSHashTable<WKWebView>.weakObjects()
    @ObservationIgnored private let canal = Canal()

    /// Gancho en FocusableWKWebView.init y KurthPageState.attach, como los demás scripts de la capa.
    static func instalar(en webView: WKWebView) { shared.instalar(webView) }

    private func instalar(_ webView: WKWebView) {
        guard Self.activo, let fuente = Self.fuente else { return }
        vistas.add(webView)
        let controlador = webView.configuration.userContentController
        guard !controladores.contains(controlador) else { return }
        controladores.add(controlador)
        controlador.addScriptMessageHandler(canal, contentWorld: Self.mundo, name: "kurthGrabadora")
        // "// Nook" al frente: los tweaks vacían los scripts en cada navegación y solo reponen los marcados.
        controlador.addUserScript(WKUserScript(source: WKUserScript.nookOwnedPrefix + " kurth: grabadora de workflows\n" + fuente,
                                               injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.mundo))
    }

    private final class Canal: NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(_ controller: WKUserContentController, didReceive mensaje: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            guard mensaje.frameInfo.isMainFrame, let cuerpo = mensaje.body as? [String: Any],
                  let webView = mensaje.webView else { replyHandler(nil, nil); return }
            MainActor.assumeIsolated {
                replyHandler(KurthWorkflows.shared.recibir(cuerpo, de: webView), nil)
            }
        }
    }

    private func recibir(_ cuerpo: [String: Any], de webView: WKWebView) -> Any? {
        switch cuerpo["tipo"] as? String {
        case "hola":
            return ["grabando": pertenece(webView)]
        case "paso":
            if let paso = cuerpo["paso"] as? [String: Any] { recibirPaso(paso, de: webView) }
            return nil
        default:
            return nil
        }
    }

    /// La pestaña de esa vista es de la ventana que se está grabando.
    private func pertenece(_ webView: WKWebView) -> Bool {
        guard grabacion?.fase == .grabando, let id = pestaña(de: webView), let tabs, let ventana else { return false }
        return tabs.displayOrder(in: ventana).contains(id)
    }

    private func pestaña(de webView: WKWebView) -> UUID? {
        (webView as? FocusableWKWebView)?.owningSession?.itemID ?? tabs?.session(for: webView)?.itemID
    }

    /// Enciende o apaga el grabador en las páginas ya abiertas (las nuevas preguntan al cargar).
    private func avisarALasVistas(_ funcion: String) async {
        for webView in vistas.allObjects {
            let dentro = funcion != "activar" || pertenece(webView)
            let codigo = "return window.__kurthGrabadora ? window.__kurthGrabadora.\(dentro ? funcion : "desactivar")() : false"
            _ = try? await webView.callAsyncJavaScript(codigo, arguments: [:], in: nil, contentWorld: Self.mundo)
        }
    }

    // MARK: - Grabar

    enum Problema: LocalizedError {
        case apagado, yaGrabando, sinVentana, noGrabando, sinNombre, noExiste(String), agenteOcupado
        var errorDescription: String? {
            switch self {
            case .apagado: "Los workflows están apagados (kurth.workflows)."
            case .yaGrabando: "Ya hay una grabación en curso."
            case .sinVentana: "No hay una ventana donde grabar."
            case .noGrabando: "No hay una grabación en curso."
            case .sinNombre: "Falta el nombre."
            case .noExiste(let n): "No existe el workflow «\(n)»."
            case .agenteOcupado: "El agente no puede recibir mensajes ahora (¿el cel está encendido?)."
            }
        }
    }

    func empezar(en ventana: BrowserWindowState, tabs: TabsController, reemplaza: String? = nil) throws {
        guard Self.activo else { throw Problema.apagado }
        guard grabacion == nil else { throw Problema.yaGrabando }
        self.tabs = tabs
        self.ventana = ventana
        pestañasNuevas = []
        var g = Grabacion(ventana: ventana.id, inicio: Date(), reemplaza: reemplaza)
        let foto = Self.foto(tabs, ventana)
        fotoAnterior = foto
        // Dónde empieza: el workflow tiene que saber desde qué página arrancar.
        if let id = ventana.selectedItemID, let pagina = foto.paginas[id], let url = pagina.url {
            var p = KurthWorkflowPaso(t: 0, tipo: .navegar)
            p.tab = id.uuidString
            p.url = url
            p.titulo = pagina.titulo
            p.detalle = "inicio"
            KurthWorkflowsModelo.agregar(p, a: &g.pasos)
        }
        grabacion = g
        observarVentana()
        Task { await avisarALasVistas("activar") }
        if Self.vozAlEmpezar { Task { await voz.encender() } }
    }

    /// Deja de captar y pasa a pedir el nombre. Antes vacía lo que la página tenía a medias (un
    /// campo escrito sin salir de él) para que no se pierda el último paso.
    func terminar() async {
        guard var g = grabacion, g.fase == .grabando else { return }
        await avisarALasVistas("vaciar")
        // Los mensajes de la página llegan por el mismo canal y en orden; un respiro para que entren.
        try? await Task.sleep(for: .milliseconds(150))
        voz.apagar()
        g = grabacion ?? g
        g.fase = .nombrando
        g.terminada = Date()
        grabacion = g
        await avisarALasVistas("desactivar")
    }

    /// "Seguir grabando" desde la tarjeta del nombre.
    func seguirGrabando() {
        guard var g = grabacion, g.fase == .nombrando else { return }
        g.fase = .grabando
        g.terminada = nil
        grabacion = g
        observarVentana()
        Task { await avisarALasVistas("activar") }
        if Self.vozAlEmpezar { Task { await voz.encender() } }
    }

    func descartar() {
        guard grabacion != nil else { return }
        voz.apagar()
        grabacion = nil
        fotoAnterior = nil
        Task { await avisarALasVistas("desactivar") }
    }

    /// El micrófono del aviso. Lo último que eligió Kurth se recuerda para la próxima grabación.
    func alternarVoz() {
        if voz.encendida {
            voz.apagar()
            UserDefaults.standard.set(false, forKey: Self.ajusteVoz)
        } else {
            UserDefaults.standard.set(true, forKey: Self.ajusteVoz)
            Task { await voz.encender() }
        }
    }

    /// Lo escrito en la caja del agente mientras se graba: nota de la grabación, no mensaje.
    func anotar(_ texto: String) {
        narrar(.nota, texto, en: Date())
    }

    private func narrar(_ tipo: KurthWorkflowPaso.Tipo, _ texto: String, en fecha: Date) {
        guard var g = grabacion, g.fase == .grabando else { return }
        var p = KurthWorkflowPaso(t: g.t(fecha), tipo: tipo)
        p.valor = texto
        KurthWorkflowsModelo.agregar(p, a: &g.pasos)
        grabacion = g
    }

    private func recibirPaso(_ d: [String: Any], de webView: WKWebView) {
        guard var g = grabacion, g.fase == .grabando, pertenece(webView) else { return }
        let deLaPagina: Set<KurthWorkflowPaso.Tipo> = [.clic, .escribir, .elegir, .marcar, .archivo, .tecla, .enviar, .scroll]
        guard let tipo = (d["tipo"] as? String).flatMap(KurthWorkflowPaso.Tipo.init(rawValue:)), deLaPagina.contains(tipo) else { return }
        func texto(_ clave: String) -> String? {
            guard let s = d[clave] as? String, !s.isEmpty else { return nil }
            return String(s.prefix(500))
        }
        let cuando = (d["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()
        var p = KurthWorkflowPaso(t: g.t(cuando), tipo: tipo)
        p.rol = texto("rol")
        p.nombre = texto("nombre")
        p.selector = texto("selector")
        p.valor = texto("valor") ?? (tipo == .escribir ? "" : nil)
        p.href = texto("href")
        p.tecla = texto("tecla")
        p.detalle = texto("detalle")
        p.secreto = (d["secreto"] as? Bool) == true ? true : nil
        p.doble = (d["doble"] as? Bool) == true ? true : nil
        // kurth: para que el replay desempate dos elementos que se llaman igual (KurthReplay.js).
        p.pos = (d["pos"] as? [NSNumber])?.map(\.doubleValue)
        p.orden = (d["orden"] as? NSNumber)?.intValue
        p.url = webView.url?.absoluteString
        p.titulo = webView.title
        p.tab = pestaña(de: webView)?.uuidString
        KurthWorkflowsModelo.agregar(p, a: &g.pasos)
        grabacion = g
    }

    // MARK: - Pestañas y direcciones (lo que la página no ve)

    private struct Foto: Equatable {
        struct Pagina: Equatable { var url: String?; var titulo: String }
        var space: UUID?
        var spaceNombre: String
        var seleccionada: UUID?
        var orden: [UUID]
        var paginas: [UUID: Pagina]
    }

    private static func foto(_ tabs: TabsController, _ v: BrowserWindowState) -> Foto {
        let orden = tabs.displayOrder(in: v)
        var paginas: [UUID: Foto.Pagina] = [:]
        for id in orden {
            guard let s = tabs.session(for: id) else { continue }
            let esWeb = ["http", "https", "file"].contains(s.url.scheme ?? "")
            paginas[id] = Foto.Pagina(url: esWeb ? s.url.absoluteString : nil, titulo: s.title)
        }
        return Foto(space: v.spaceID, spaceNombre: v.spaceID.flatMap { tabs.space($0)?.name } ?? "",
                    seleccionada: v.selectedItemID, orden: orden, paginas: paginas)
    }

    /// Observation, no sondeo: el aviso llega cuando cambia algo que la foto leyó (pestañas,
    /// selección, dirección o título de alguna) y se vuelve a pedir después de cada cambio.
    private func observarVentana() {
        guard grabacion?.fase == .grabando, let tabs, let ventana else { return }
        withObservationTracking {
            _ = Self.foto(tabs, ventana)
        } onChange: { [weak self] in
            Task { @MainActor in self?.cambioEnLaVentana() }
        }
    }

    private func cambioEnLaVentana() {
        guard var g = grabacion, g.fase == .grabando, let tabs, let ventana, let antes = fotoAnterior else { return }
        let ahora = Self.foto(tabs, ventana)
        defer { fotoAnterior = ahora; observarVentana() }
        guard ahora != antes else { return }
        let t = g.t()
        func paso(_ tipo: KurthWorkflowPaso.Tipo, _ id: UUID, _ pagina: Foto.Pagina?) -> KurthWorkflowPaso {
            var p = KurthWorkflowPaso(t: t, tipo: tipo)
            p.tab = id.uuidString
            p.url = pagina?.url
            p.titulo = pagina?.titulo
            return p
        }
        if ahora.space != antes.space {
            var p = KurthWorkflowPaso(t: t, tipo: .space)
            p.nombre = ahora.spaceNombre
            KurthWorkflowsModelo.agregar(p, a: &g.pasos)
            grabacion = g
            return
        }
        for id in ahora.orden where !antes.orden.contains(id) {
            pestañasNuevas.insert(id)
            KurthWorkflowsModelo.agregar(paso(.pestañaNueva, id, ahora.paginas[id]), a: &g.pasos)
        }
        for id in antes.orden where !ahora.orden.contains(id) {
            KurthWorkflowsModelo.agregar(paso(.cerrarPestaña, id, antes.paginas[id]), a: &g.pasos)
        }
        if let id = ahora.seleccionada, id != antes.seleccionada {
            KurthWorkflowsModelo.agregar(paso(.cambiarPestaña, id, ahora.paginas[id]), a: &g.pasos)
        }
        for id in ahora.orden where antes.orden.contains(id) {
            let a = antes.paginas[id], b = ahora.paginas[id]
            if let url = b?.url, url != a?.url {
                // Una pestaña que despierta (no tenía página cargada) no es una navegación de Kurth; la
                // primera dirección de una pestaña abierta durante la grabación, sí.
                guard a?.url != nil || pestañasNuevas.contains(id) else { continue }
                KurthWorkflowsModelo.agregar(paso(.navegar, id, b), a: &g.pasos)
            } else if let titulo = b?.titulo, titulo != a?.titulo {
                KurthWorkflowsModelo.ponerTitulo(titulo, tab: id.uuidString, t: t, en: &g.pasos)
            }
        }
        grabacion = g
    }

    // MARK: - Guardar

    /// Guarda la grabación con ese nombre y le pide al agente el skill. Devuelve el workflow guardado.
    @discardableResult
    func guardar(titulo crudo: String, descripcion: String) throws -> KurthWorkflow {
        guard let g = grabacion else { throw Problema.noGrabando }
        let titulo = crudo.trimmingCharacters(in: .whitespacesAndNewlines)
        let nombre = g.reemplaza ?? KurthGuardarSkill.nombreValido(titulo)
        guard !nombre.isEmpty else { throw Problema.sinNombre }
        let previo = tienda.cargar(nombre)
        var wf = previo ?? KurthWorkflow(nombre: nombre, titulo: titulo, descripcion: "")
        if !titulo.isEmpty { wf.titulo = titulo }
        let nueva = descripcion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nueva.isEmpty { wf.descripcion = nueva }
        wf.pasos = g.pasos
        wf.duracion = g.duracion()
        wf.actualizado = Date()
        wf.skillAlDia = false
        try tienda.guardar(wf)
        grabacion = nil
        fotoAnterior = nil
        recargar()
        pedirAlAgente("Crea el workflow «\(wf.titulo)» con lo que grabé",
                      KurthWorkflowsModelo.instruccionesParaSkill(wf, rutaJSON: tienda.ruta(nombre).path, reemplaza: previo != nil))
        return wf
    }

    // MARK: - Editar, renombrar, borrar

    /// Guardar desde el editor del popover: descripción, pasos quitados, instrucciones de siempre y
    /// un pedido en lenguaje natural. Si cambió algo que el skill usa, el agente lo reescribe.
    func editar(_ nombre: String, titulo: String, descripcion: String, instrucciones: String,
                quitar: Set<UUID>, pedido: String) throws {
        guard var wf = tienda.cargar(nombre) else { throw Problema.noExiste(nombre) }
        let antes = wf
        let t = titulo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { wf.titulo = t }
        wf.descripcion = descripcion.trimmingCharacters(in: .whitespacesAndNewlines)
        wf.instrucciones = instrucciones.trimmingCharacters(in: .whitespacesAndNewlines)
        wf.pasos.removeAll { quitar.contains($0.id) }
        let pedidoLimpio = pedido.trimmingCharacters(in: .whitespacesAndNewlines)
        let tocaElSkill = wf.pasos != antes.pasos || wf.descripcion != antes.descripcion
            || wf.instrucciones != antes.instrucciones || !pedidoLimpio.isEmpty
        guard wf != antes || !pedidoLimpio.isEmpty else { return }
        wf.actualizado = Date()
        if tocaElSkill { wf.skillAlDia = false }
        try tienda.guardar(wf)
        recargar()
        guard tocaElSkill else { return }
        pedirAlAgente("Actualiza el workflow «\(wf.titulo)»" + (pedidoLimpio.isEmpty ? "" : ": \(pedidoLimpio)"),
                      KurthWorkflowsModelo.instruccionesParaSkill(wf, rutaJSON: tienda.ruta(nombre).path, reemplaza: true,
                                                                  pedido: pedidoLimpio))
    }

    /// Solo redactar otra vez el skill desde la grabación (menú …).
    func redactarSkill(_ nombre: String) throws {
        guard let wf = tienda.cargar(nombre) else { throw Problema.noExiste(nombre) }
        pedirAlAgente("Vuelve a escribir el skill de «\(wf.titulo)»",
                      KurthWorkflowsModelo.instruccionesParaSkill(wf, rutaJSON: tienda.ruta(nombre).path, reemplaza: true))
    }

    /// Nuevo título. Si cambia el nombre corto, cambia el archivo y el agente mueve el skill.
    @discardableResult
    func renombrar(_ nombre: String, a titulo: String) throws -> String {
        guard var wf = tienda.cargar(nombre) else { throw Problema.noExiste(nombre) }
        let t = titulo.trimmingCharacters(in: .whitespacesAndNewlines)
        let nuevo = KurthGuardarSkill.nombreValido(t)
        guard !nuevo.isEmpty else { throw Problema.sinNombre }
        wf.titulo = t
        wf.actualizado = Date()
        if nuevo != nombre {
            guard !tienda.existe(nuevo) else { throw Problema.noExiste("\(nuevo) (ya hay otro con ese nombre)") }
            wf.nombre = nuevo
            try tienda.guardar(wf)
            try? tienda.borrar(nombre)
            pedirAlAgente("Renombra el workflow «\(nombre)» a «\(nuevo)»",
                          KurthWorkflowsModelo.instruccionesParaRenombrar(de: nombre, a: nuevo))
        } else {
            try tienda.guardar(wf)
        }
        recargar()
        reprogramar()
        return nuevo
    }

    func borrar(_ nombre: String) throws {
        guard let wf = tienda.cargar(nombre) else { throw Problema.noExiste(nombre) }
        try tienda.borrar(nombre)
        recargar()
        reprogramar()
        pedirAlAgente("Borra el skill del workflow «\(wf.titulo)»", KurthWorkflowsModelo.instruccionesParaBorrar(nombre))
    }

    /// Lo que registra el agente al terminar de escribir el skill (kurth_workflow define).
    func definir(_ nombre: String, descripcion: String?, parametros: [KurthWorkflowParametro]?) throws -> KurthWorkflow {
        guard var wf = tienda.cargar(nombre) else { throw Problema.noExiste(nombre) }
        if let d = descripcion?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { wf.descripcion = d }
        if let parametros {
            wf.parametros = parametros.filter { !$0.nombre.isEmpty }
            let vigentes = Set(wf.parametros.map(\.nombre))
            wf.ultimosValores = wf.ultimosValores.filter { vigentes.contains($0.key) }
            if var p = wf.programacion {
                p.valores = p.valores.filter { vigentes.contains($0.key) }
                wf.programacion = p
            }
        }
        wf.skillAlDia = true
        try tienda.guardar(wf)
        KurthMemorias.shared.desdeWorkflow(wf) // kurth: sus sitios y cuentas pasan a las memorias de Nook
        recargar()
        return wf
    }

    /// El SKILL.md, solo para leerlo en el editor. nil si el agente todavía no lo escribe.
    func textoDelSkill(_ nombre: String) -> String? {
        let ruta = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/\(nombre)/SKILL.md")
        return try? String(contentsOf: ruta, encoding: .utf8)
    }

    // MARK: - Mandar al agente

    /// Lo que no pudo salir porque el agente estaba ocupado: sale al terminar su turno.
    @ObservationIgnored private var cola: [Envio] = []

    private struct Envio {
        let visible: String
        let instrucciones: String
        var alSalir: (() -> Void)?
    }

    /// Abre el panel del agente en la ventana activa, lo arranca si hace falta y manda. Si está a
    /// media respuesta, queda en la cola y sale cuando termine.
    @discardableResult
    func pedirAlAgente(_ visible: String, _ instrucciones: String, alSalir: (() -> Void)? = nil) -> Bool {
        let envio = Envio(visible: visible, instrucciones: instrucciones, alSalir: alSalir)
        if mandar(envio) { return true }
        cola.append(envio)
        return false
    }

    private func mandar(_ envio: Envio) -> Bool {
        guard let agente = KurthAgentService.actual else { return false }
        if let v = ventanaParaElPanel(), !v.isSidebarAIChatVisible {
            withAnimation(.easeInOut(duration: 0.2)) { v.isSidebarAIChatVisible = true }
        }
        agente.arrancar()
        guard agente.aceptaMensajes else { return false }
        envio.alSalir?()
        agente.enviar(envio.visible, paraElAgente: envio.instrucciones)
        return true
    }

    private func ventanaParaElPanel() -> BrowserWindowState? {
        if let g = grabacion, let v = ventana, v.id == g.ventana { return v }
        return browserManager?.windowRegistry?.activeWindow ?? browserManager?.windowRegistry?.windows.values.first ?? ventana
    }

    private func despacharCola() {
        while let primero = cola.first, mandar(primero) { cola.removeFirst() }
    }

    // MARK: - Correr

    /// La corrida que se sigue: su resultado sale de los turnos del agente que vengan después.
    struct CorridaActiva {
        let nombre: String
        let corrida: UUID
        let programada: Bool
        var turnos = 0
        var avisada = false
    }

    @ObservationIgnored private(set) var activa: CorridaActiva?

    func correr(_ nombre: String, valores: [String: String], programada: Bool) throws {
        guard let wf = tienda.cargar(nombre) else { throw Problema.noExiste(nombre) }
        // El replay exacto, sin LLM (KurthWorkflowsReplay). El agente completo solo si no hay pasos.
        if wf.acciones > 0 {
            try KurthWorkflowsReplay.shared.correr(nombre, valores: valores, programada: programada)
            return
        }
        try correrConAgente(nombre, valores: valores, programada: programada)
    }

    /// La corrida de antes del replay: el agente lee el skill y lo sigue. Programada, su sesión va en
    /// "sin restricciones" y la guardia de lo irreversible no frena mientras dura (Kurth, 26 sep).
    func correrConAgente(_ nombre: String, valores: [String: String], programada: Bool) throws {
        guard var wf = tienda.cargar(nombre) else { throw Problema.noExiste(nombre) }
        var efectivos: [String: String] = [:]
        for p in wf.parametros { efectivos[p.nombre] = valores[p.nombre] ?? wf.valorInicial(p) }
        if !programada { wf.ultimosValores.merge(efectivos) { $1 } }
        let corrida = KurthWorkflowCorrida(inicio: Date(), estado: .corriendo, programada: programada)
        wf.corridas.append(corrida)
        try tienda.guardar(wf)
        recargar()
        let visible = KurthWorkflowsModelo.textoVisibleDeCorrida(wf, valores: efectivos, programada: programada)
        let instrucciones = KurthWorkflowsModelo.instruccionesParaCorrer(wf, valores: efectivos, programada: programada,
                                                                         rutaJSON: tienda.ruta(nombre).path)
        pedirAlAgente(visible, instrucciones) { [weak self] in
            // Si esperó en la cola, la corrida empieza cuando de verdad sale.
            self?.activa = CorridaActiva(nombre: nombre, corrida: corrida.id, programada: programada)
            self?.actualizarCorrida(nombre, corrida.id) { $0.inicio = Date(); $0.modo = "agente" }
            if programada {
                KurthAgentService.actual?.forzarModo("bypassPermissions")
                KurthCabeza.shared.autorizarCorridaDelAgente(true)
            }
        }
    }

    private func actualizarCorrida(_ nombre: String, _ id: UUID, _ cambio: (inout KurthWorkflowCorrida) -> Void) {
        guard var wf = tienda.cargar(nombre), let i = wf.corridas.firstIndex(where: { $0.id == id }) else { return }
        cambio(&wf.corridas[i])
        try? tienda.guardar(wf)
        recargar()
    }

    /// Gancho en KurthAgentService.cerrarTurno: se lee cómo acabó la corrida y sale lo encolado.
    func turnoTerminado() {
        defer { despacharCola() }
        // El turno era el del respaldo de un replay: su respuesta es para el replay.
        if let agente = KurthAgentService.actual,
           KurthWorkflowsReplay.shared.turnoDelAgente(agente.mensajes.last { $0.autor == .agente }?.texto ?? "") { return }
        guard var a = activa, let agente = KurthAgentService.actual else { return }
        a.turnos += 1
        activa = a
        let ultimo = agente.mensajes.last { $0.autor == .agente }?.texto ?? ""
        let titulo = workflow(a.nombre)?.titulo ?? a.nombre
        var estado: KurthWorkflowCorrida.Estado
        var resumen: String
        if let r = KurthWorkflowsModelo.resultado(de: ultimo) {
            (estado, resumen) = r
        } else if a.turnos > 1 {
            // Ya estaba esperando y este turno fue de otra plática: no se toca la corrida.
            return
        } else if ultimo.contains("⚠️") || ultimo.isEmpty {
            estado = .fallo
            resumen = ultimo.isEmpty ? "El agente no respondió" : Self.ultimaLinea(ultimo)
        } else {
            estado = .termino
            resumen = Self.ultimaLinea(ultimo)
        }
        if KurthCabeza.shared.pendiente != nil { estado = .esperando }
        actualizarCorrida(a.nombre, a.corrida) {
            $0.estado = estado
            $0.resumen = resumen
            $0.fin = estado == .esperando ? nil : Date()
        }
        // Programada: el modo y la guardia vuelven a lo de siempre en cuanto el agente suelta el turno.
        if a.programada {
            KurthAgentService.actual?.forzarModo(nil)
            KurthCabeza.shared.autorizarCorridaDelAgente(false)
        }
        switch estado {
        case .esperando:
            if !a.avisada { avisarQueEspera(titulo, resumen) }
        default:
            activa = nil
            if a.programada || !NSApp.isActive {
                notificar(estado == .fallo ? "Falló «\(titulo)»" : "Terminó «\(titulo)»", resumen)
            }
        }
    }

    /// Gancho en la tarjeta de permiso del agente y en la confirmación de un botón delicado.
    func esperandoConfirmacion(_ que: String) {
        guard let a = activa, !a.avisada else { return }
        let titulo = workflow(a.nombre)?.titulo ?? a.nombre
        actualizarCorrida(a.nombre, a.corrida) { $0.estado = .esperando; $0.resumen = que }
        avisarQueEspera(titulo, que)
    }

    private func avisarQueEspera(_ titulo: String, _ que: String) {
        activa?.avisada = true
        notificar("El workflow «\(titulo)» espera tu confirmación", que)
    }

    private static func ultimaLinea(_ texto: String) -> String {
        let linea = texto.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        return String(linea.prefix(160))
    }
}
