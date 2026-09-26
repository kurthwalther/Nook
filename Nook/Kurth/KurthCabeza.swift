// Licensed under GPL-3.0. See LICENSE.
//
//  KurthCabeza.swift
//  Nook (rama kurth)
//
//  Modo "con cabeza" del agente (plan del barrido de Ernest, punto 6; maqueta vista por Kurth el
//  26 sep: "sí, pero más sutil y bonito"). Cuando el agente maneja una pestaña con las
//  herramientas del MCP, Kurth tiene que poder ver dónde, pararlo y aprobar lo que no se deshace.
//  Este archivo es el estado; lo que se pinta está en:
//   · KurthCabezaGancho (NookUI): el anillo fino en la pestaña, en la tira y en la lateral.
//   · KurthCabezaAviso.swift: la cápsula de vidrio sobre la página con "Detener".
//   · KurthAgentPlan.swift: la línea del plan sobre la caja del panel.
//   · KurthAgentChat: la tarjeta de confirmación (sola, o dentro de la de permiso).
//
//  Quién "controla" una pestaña: la última a la que el MCP le mandó una acción que cambia la página
//  (click, escribir, llenar, navegar…; leer no cuenta). Si la acción llegó durante un turno del
//  panel, la marca dura hasta que ese turno termine: el agente piensa entre acción y acción y el
//  anillo no debe parpadear. Si llegó de otro cliente del MCP (kurth/mcp.sh, Claude Code en la
//  terminal), se apaga sola a los pocos segundos sin acciones, porque ese cliente no avisa cuando
//  acaba.
//
//  Detener corta el turno del panel y, además, deja el MCP rechazando acciones un rato: así también
//  para a un lote (batch) a medias o a un cliente externo, que no tienen otra forma de enterarse.
//
//  Lo irreversible: click ya exigía confirmado: true en botones de comprar, pagar, borrar o
//  publicar. Ahora, cuando lo frena, el botón se marca en la página con un anillo naranja fino y
//  el panel lo dice en lenguaje humano ("Va a publicar en …"). Si Kurth lo aprueba desde la
//  tarjeta (la de permiso de ACP o la de confirmación), ese mismo botón en esa misma pestaña queda
//  autorizado una vez por un minuto: sin esto, en modo manual se le preguntaba tres veces lo mismo.
//
//  Se apaga con kurth.agentConCabeza = false (la guardia de confirmado del MCP sigue igual).
//

import AppKit
import Foundation
import Observation
import WebKit
import NookUI

@MainActor
@Observable
final class KurthCabeza {
    static let shared = KurthCabeza()

    static let clave = "kurth.agentConCabeza"
    static var activo: Bool { UserDefaults.standard.object(forKey: clave) as? Bool ?? true }

    /// Las herramientas del MCP que cambian la página. Leer (snapshot, find, read_page, page_text,
    /// screenshot_tab, wait_for) y señalar no cuentan: leer una pestaña no es manejarla.
    /// run_js queda fuera a propósito: casi siempre se usa para leer.
    static let herramientasQueActuan: Set<String> = [
        "click", "type_text", "fill_form", "press_key", "hover", "scroll", "select_option",
        "upload_file", "act", "navigate_tab", "handle_dialog", "batch",
    ]

    /// Para resolver pestañas desde el permiso de ACP, que llega antes que cualquier llamada al MCP.
    /// Lo pone el panel al aparecer (KurthAgentChat) y KurthCopilot en cada llamada.
    @ObservationIgnored weak var browserManager: BrowserManager?

    // MARK: - Pestaña controlada

    @ObservationIgnored private var delPanel = false
    @ObservationIgnored private var apagado: Task<Void, Never>?
    /// Sin acciones en este tiempo, un cliente externo ya terminó (no avisa).
    private static let esperaDeClienteExterno: Duration = .seconds(6)

    /// Lo llama KurthCopilot antes de cada acción que cambia la página.
    func actuando(en tab: UUID) {
        guard Self.activo else { return }
        KurthCabezaGancho.shared.controlada = tab
        delPanel = KurthAgentService.actual?.estado == .trabajando
        apagado?.cancel()
        guard !delPanel else { return }
        apagado = Task { [weak self] in
            try? await Task.sleep(for: Self.esperaDeClienteExterno)
            guard !Task.isCancelled else { return }
            self?.soltar()
        }
    }

    private func soltar() {
        apagado?.cancel()
        apagado = nil
        KurthCabezaGancho.shared.controlada = nil
    }

    // MARK: - Detener

    /// Hasta cuándo el MCP rechaza acciones después de Detener. Se levanta antes si Kurth escribe
    /// otro mensaje en el panel: ahí ya quiere que siga.
    @ObservationIgnored private var detenidoHasta: Date?
    private static let pausaTrasDetener: TimeInterval = 30

    func detener() {
        detenidoHasta = Date().addingTimeInterval(Self.pausaTrasDetener)
        KurthAgentService.actual?.cancelar()
        soltar()
        descartarPendiente()
    }

    /// Para KurthCopilot: si Kurth detuvo al agente, el texto con que se rechaza la acción.
    func rechazoPorDetenido() -> String? {
        guard let hasta = detenidoHasta else { return nil }
        guard hasta > Date() else { detenidoHasta = nil; return nil }
        return "Kurth te detuvo desde Nook. No sigas actuando en el navegador; termina el turno y espera su siguiente mensaje."
    }

    // MARK: - Turnos del panel (KurthAgentService)

    /// Cuenta los mensajes de Kurth en el panel. Un turno puede cerrarse dos veces (al volver
    /// session/prompt y con el evento de fin), así que lo que dura "un turno" se mide con esto y no
    /// contando cierres.
    @ObservationIgnored private var turno = 0

    func nuevoMensaje() {
        detenidoHasta = nil
        turno += 1
    }

    func turnoTerminado() {
        if delPanel { soltar() }
        // Un botón que esperaba confirmación sobrevive al turno en que se frenó (el agente pregunta
        // y termina) y al siguiente no: si Kurth contestó otra cosa, ya no aplica.
        if let p = pendiente, p.turno < turno { descartarPendiente() }
    }

    // MARK: - Lo irreversible

    struct Pendiente: Identifiable, Equatable {
        let id = UUID()
        let tab: UUID
        /// Referencia del copiloto (@eN) del botón; nil si vino de act (uid de WebKit, sin anillo).
        let ref: String?
        /// El texto del botón tal como lo nombra la página, p. ej. "Publicar".
        let boton: String
        /// El verbo en español: publicar, comprar, pagar, borrar, transferir, cancelar la suscripción.
        let verbo: String
        let url: URL
        /// El turno del panel en que se frenó (KurthCabeza.turno).
        let turno: Int

        /// "Va a publicar en business.facebook.com".
        @MainActor var frase: String {
            let sitio = KurthTopBarView.shortHost(url)
            return "Va a \(verbo) en \(sitio)"
        }

        /// La dirección corta, sin esquema ni consulta: dónde está el botón.
        var direccion: String {
            let host = url.host() ?? ""
            let ruta = url.path()
            return ruta.count > 1 ? host + ruta : host
        }
    }

    private(set) var pendiente: Pendiente?
    @ObservationIgnored private weak var vistaDeLaMarca: WKWebView?
    @ObservationIgnored private var marca: String?

    /// Una autorización de un solo uso para un botón delicado: la da Kurth al aprobar la tarjeta.
    @ObservationIgnored private var autorizacion: (tab: UUID, ref: String?, hasta: Date)?

    /// click (o fill_form, o act) frenó un botón delicado: se marca en la página y se anota para
    /// la tarjeta. Si ya estaba anotado ese mismo botón, no se repite la marca.
    func pedirConfirmacion(tab: UUID, ref: String?, descripcion: String, accion: String, url: URL, webView: WKWebView) async {
        guard Self.activo else { return }
        if let p = pendiente, p.tab == tab, p.ref == ref { return }
        descartarPendiente()
        pendiente = Pendiente(tab: tab, ref: ref, boton: Self.textoDelBoton(descripcion),
                              verbo: Self.verbo(de: accion), url: url, turno: turno)
        if let frase = pendiente?.frase { KurthWorkflows.shared.esperandoConfirmacion(frase) } // kurth: avisa si corre un workflow
        guard let ref else { return }
        let id = "espera-" + UUID().uuidString.prefix(6).lowercased()
        let puesto = try? await KurthCopilot.enMarcas(
            webView, "return window.__kurth.marcas.elemento({id, autor: 'agente', ref, espera: true})",
            ["id": id, "ref": ref])
        guard puesto != nil else { return }
        marca = id
        vistaDeLaMarca = webView
    }

    /// El click delicado ya va (con confirmado o autorizado): fuera marca y tarjeta.
    func confirmada(tab: UUID) {
        guard pendiente?.tab == tab else { return }
        descartarPendiente()
    }

    func descartarPendiente() {
        pendiente = nil
        if let marca, let vista = vistaDeLaMarca {
            Task { _ = try? await KurthCopilot.enMarcas(vista, "return window.__kurth.marcas.quitar(id)", ["id": marca]) }
        }
        marca = nil
        vistaDeLaMarca = nil
    }

    /// Kurth aprobó en una tarjeta: ese botón, en esa pestaña, pasa una vez en el próximo minuto.
    func autorizar(_ p: Pendiente) {
        autorizacion = (p.tab, p.ref, Date().addingTimeInterval(60))
    }

    /// Para la guardia de click: consume la autorización si es de este botón.
    func tomarAutorizacion(tab: UUID, ref: String?) -> Bool {
        guard let a = autorizacion, a.tab == tab, a.hasta > Date(), a.ref == nil || a.ref == ref else { return false }
        autorizacion = nil
        return true
    }

    /// La respuesta desde la tarjeta de confirmación del panel (cuando el agente preguntó por chat).
    func responder(_ si: Bool) {
        guard let p = pendiente else { return }
        let agente = KurthAgentService.actual
        if si {
            autorizar(p)
            agente?.enviar("Sí, adelante: \(p.verbo) (botón «\(p.boton)»).")
        } else {
            descartarPendiente()
            agente?.enviar("No, no lo hagas.")
        }
    }

    // MARK: - Desde el permiso de ACP

    /// Para la tarjeta de permiso: si lo que pide el agente es un click del MCP de Nook sobre un botón
    /// delicado, lo anota (con su anillo) y lo devuelve. ACP no dice si algo es irreversible; se sabe
    /// por la herramienta (el título trae "click", "batch"…) y por el texto del botón en la página.
    /// Tiene tope: si la página no contesta en 1.5 s, la tarjeta sale como siempre (genérica) en
    /// vez de dejar al agente esperando; la guardia de click sigue frenando el botón después.
    func revisarPermiso(titulo: String, entrada: KurthJSON?) async -> Pendiente? {
        let herramienta = Self.herramienta(de: titulo)
        guard Self.activo, herramienta == "click" || herramienta == "batch" else { return nil }
        return await withTaskGroup(of: Pendiente?.self) { grupo in
            grupo.addTask { await KurthCabeza.shared.leerPermiso(herramienta, entrada: entrada) }
            grupo.addTask { try? await Task.sleep(for: .milliseconds(1500)); return nil }
            let primero = await grupo.next() ?? nil
            grupo.cancelAll()
            return primero
        }
    }

    private func leerPermiso(_ herramienta: String, entrada: KurthJSON?) async -> Pendiente? {
        guard let bm = browserManager, let entrada, let args = Self.diccionario(entrada) else { return nil }
        var clicks: [[String: Any]] = []
        switch herramienta {
        case "click": clicks = [args]
        case "batch":
            // En un lote, el primer click delicado es el que importa: ahí se detendría.
            for paso in args["acciones"] as? [[String: Any]] ?? [] where paso["tool"] as? String == "click" {
                var a = paso["args"] as? [String: Any] ?? [:]
                if a["tabId"] == nil, let t = args["tabId"] { a["tabId"] = t }
                clicks.append(a)
            }
        default: return nil
        }
        for a in clicks {
            guard let boton = await KurthCopilot.botonDelicado(a, bm: bm) else { continue }
            await pedirConfirmacion(tab: boton.tab, ref: boton.ref, descripcion: boton.descripcion,
                                    accion: boton.accion, url: boton.url, webView: boton.webView)
            return pendiente
        }
        return nil
    }

    // MARK: - Texto

    /// "mcp__nook__click" → "click". Claude Code titula así las herramientas MCP; si algún día manda
    /// otro formato, se busca el nombre dentro del título.
    static func herramienta(de titulo: String) -> String {
        let t = titulo.lowercased()
        if let ultimo = t.components(separatedBy: "__").last, t.contains("__") {
            return ultimo.trimmingCharacters(in: .whitespaces)
        }
        for nombre in ["batch", "click"] where t.contains(nombre) { return nombre }
        return t
    }

    /// `button "Publicar"` → "Publicar". Sin comillas, la descripción entera.
    static func textoDelBoton(_ descripcion: String) -> String {
        if let a = descripcion.firstIndex(of: "\""), let b = descripcion[descripcion.index(after: a)...].firstIndex(of: "\"") {
            let texto = String(descripcion[descripcion.index(after: a)..<b]).trimmingCharacters(in: .whitespaces)
            if !texto.isEmpty { return texto }
        }
        return descripcion.trimmingCharacters(in: .whitespaces)
    }

    /// De la palabra que disparó la guardia (KurthCopilot.accionDelicada) al verbo que se lee.
    static func verbo(de accion: String) -> String {
        switch accion {
        case "pagar", "pago", "pay": return "pagar"
        case "eliminar", "borrar", "delete", "remove": return "borrar"
        case "publicar", "publish": return "publicar"
        case "transferir", "transfer": return "transferir"
        case "unsubscribe", "cancelar suscripcion", "darse de baja": return "cancelar la suscripción"
        default: return "comprar"
        }
    }

    private static func diccionario(_ json: KurthJSON) -> [String: Any]? {
        guard let datos = try? JSONEncoder().encode(json) else { return nil }
        return (try? JSONSerialization.jsonObject(with: datos)) as? [String: Any]
    }

    private init() {}
}
