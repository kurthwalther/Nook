// Licensed under GPL-3.0. See LICENSE.
//
//  KurthBoosts.swift
//  Nook (rama kurth)
//
//  Boosts por sitio (plan del 26 sep, punto 5; lo que más se extraña de Arc): CSS y JS propios por
//  host exacto, guardados en Application Support/com.gstudios.nook/Kurth/boosts.json.
//  - Cada vista web recibe los scripts al crearse (KurthBoosts.instalar, gancho en
//    FocusableWKWebView.init y KurthPageState.attach). Se filtran solos por host, así que no hay
//    que tocar nada en cada navegación; los tweaks los respetan porque llevan "// Nook".
//  - Al guardar, el CSS cambia en vivo en las pestañas abiertas de ese host (misma <style>, mismo
//    mundo aislado); si cambia el JS se recargan, porque correr un JS nuevo encima del viejo no es
//    lo mismo que cargarlo limpio.
//  - "Describe lo que quieres" (KurthBoostPopover) le manda el pedido al agente del panel, y el
//    agente escribe y aplica el código con la herramienta MCP kurth_boost.
//  Ajuste kurth.boosts (true = aplicar). Modelo y scripts: KurthBoostsModelo.swift.
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
final class KurthBoosts {
    static let shared = KurthBoosts()

    /// Ventana cuyo popover de Boost debe abrirse (lo pide el panel de opciones; KurthBoostAncla lo
    /// abre y lo limpia). Espera a que el panel de opciones termine de cerrarse: dos popovers
    /// seguidos en el mismo instante se pisan.
    private(set) var popoverPedido: UUID?

    func abrirPopover(en ventana: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.popoverPedido = ventana }
    }

    func popoverAbierto() { popoverPedido = nil }
    @ObservationIgnored fileprivate static let log = Logger(subsystem: "com.nook.browser", category: "KurthBoosts")

    static let ajuste = "kurth.boosts"
    static var aplicar: Bool { UserDefaults.standard.object(forKey: ajuste) as? Bool ?? true }

    static let archivo: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.gstudios.nook/Kurth/boosts.json")
    }()

    /// Por host. Lo leen la cápsula (el punto) y el popover.
    private(set) var boosts: [String: KurthBoost] = [:]
    /// Copia observable de kurth.boosts: UserDefaults no avisa a SwiftUI, y el punto de la cápsula
    /// tiene que apagarse en cuanto el ajuste cambia por MCP.
    private(set) var aplicando = KurthBoosts.aplicar

    /// Los scripts que tocan hoy (según boosts y el ajuste), ya construidos: cada vista nueva recibe
    /// estos mismos objetos, sin volver a armar el texto.
    @ObservationIgnored private var scripts: [WKUserScript] = []
    @ObservationIgnored private let controladores = NSHashTable<WKUserContentController>.weakObjects()
    @ObservationIgnored private let vistas = NSHashTable<WKWebView>.weakObjects()
    @ObservationIgnored private var reposicion: Task<Void, Never>?
    @ObservationIgnored private var escritura: Task<Void, Never>?

    private init() {
        assert(KurthBoostsModelo.prefijo.hasPrefix(WKUserScript.nookOwnedPrefix),
               "Sin el marcador de NookOwned los tweaks borran los boosts en cada navegación")
        cargar()
        scripts = Self.aplicar ? KurthBoostsModelo.scripts(Array(boosts.values)) : []
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KurthBoosts.shared.escribirYa() }
        }
    }

    // MARK: - Consultas

    func boost(para url: URL?) -> KurthBoost? {
        KurthBoostsModelo.host(de: url).flatMap { boosts[$0] }
    }

    /// Para el punto de la cápsula: hay boost, está encendido y el ajuste general también.
    func aplica(en url: URL?) -> Bool {
        guard aplicando, let b = boost(para: url) else { return false }
        return b.encendido && !b.vacio
    }

    // MARK: - Instalación en cada vista web

    static func instalar(en webView: WKWebView) { shared.instalar(webView) }

    private func instalar(_ webView: WKWebView) {
        vistas.add(webView)
        let controlador = webView.configuration.userContentController
        guard !controladores.contains(controlador) else { return }
        controladores.add(controlador)
        // Controlador nuevo (BrowserConfiguration.freshUserContentController, uno por pestaña): se
        // agregan sin vaciar, porque la extensión ya pudo meter los suyos y no se entera si se borran.
        guard !controlador.userScripts.contains(where: { $0.source.hasPrefix(KurthBoostsModelo.prefijo) }) else {
            reponer(en: controlador)
            return
        }
        scripts.forEach(controlador.addUserScript)
    }

    /// Cambia los scripts de los boosts en un controlador que ya los tenía. No hay API para quitar
    /// uno solo: se vacía y se reponen los de Nook, igual que los tweaks (WKUserScript+NookOwned).
    private func reponer(en controlador: WKUserContentController) {
        // userScripts es un proxy perezoso: todo lo que se necesite se lee antes de vaciar.
        let todos = controlador.userScripts
        let actuales = todos.filter { $0.source.hasPrefix(KurthBoostsModelo.prefijo) }.map(\.source)
        guard actuales != scripts.map(\.source) else { return }
        // Sin boosts puestos todavía, basta con agregar: vaciar se lleva los de las extensiones.
        if actuales.isEmpty {
            scripts.forEach(controlador.addUserScript)
            return
        }
        let otros = todos.nookOwned.filter { !$0.source.hasPrefix(KurthBoostsModelo.prefijo) }
        controlador.removeAllUserScripts()
        otros.forEach(controlador.addUserScript)
        scripts.forEach(controlador.addUserScript)
    }

    /// Rearma los scripts y los repone en todas las pestañas. `ya`: antes de recargar (la recarga
    /// tiene que ver el JS nuevo); si no, espera a que se deje de escribir en el editor de CSS,
    /// porque reponer cuesta una llamada a WebKit por script y por pestaña.
    private func reponerEnTodas(ya: Bool) {
        reposicion?.cancel()
        let hacer = { [weak self] in
            guard let self else { return }
            self.scripts = Self.aplicar ? KurthBoostsModelo.scripts(Array(self.boosts.values)) : []
            self.controladores.allObjects.forEach(self.reponer(en:))
        }
        if ya { hacer(); return }
        reposicion = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            hacer()
            self?.reposicion = nil
        }
    }

    // MARK: - Cambios

    struct Resultado {
        var boost: KurthBoost?
        /// Pestañas donde el CSS cambió sin recargar.
        var enVivo = 0
        /// Pestañas recargadas porque cambió el JS.
        var recargadas = 0
    }

    enum Problema: LocalizedError {
        case host(String)
        case sintaxis(String)
        var errorDescription: String? {
            switch self {
            case .host(let texto): "“\(texto)” no es un host válido (ej. www.facebook.com)"
            case .sintaxis(let error): "El JS no compila: \(error). No se guardó nada."
            }
        }
    }

    /// Crea o cambia el boost de `host`; lo que llega nil se queda como estaba. Si al final no queda
    /// ni CSS ni JS, el boost se borra (un boost vacío solo pintaría el punto). `recargar`: false
    /// guarda un JS nuevo sin recargar (se ve en la próxima carga).
    @discardableResult
    func guardar(host texto: String, css: String? = nil, js: String? = nil, nombre: String? = nil,
                 encendido: Bool? = nil, recargar: Bool = true) throws -> Resultado {
        guard let host = KurthBoostsModelo.host(de: texto) else { throw Problema.host(texto) }
        if let js, let error = KurthBoostsModelo.errorDeSintaxis(js) { throw Problema.sintaxis(error) }
        let antes = boosts[host]
        var nuevo = antes ?? KurthBoost(host: host, nombre: "", css: "", js: "", encendido: true, actualizado: Date())
        if let css { nuevo.css = css }
        if let js { nuevo.js = js }
        if let nombre { nuevo.nombre = nombre.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let encendido { nuevo.encendido = encendido }
        guard nuevo != antes else { return Resultado(boost: antes) }
        nuevo.actualizado = Date()
        boosts[host] = nuevo.vacio ? nil : nuevo
        return aplicarCambio(host: host, antes: antes, despues: boosts[host], recargar: recargar)
    }

    @discardableResult
    func borrar(host texto: String) throws -> Resultado {
        guard let host = KurthBoostsModelo.host(de: texto) else { throw Problema.host(texto) }
        guard let antes = boosts.removeValue(forKey: host) else { return Resultado() }
        return aplicarCambio(host: host, antes: antes, despues: nil, recargar: true)
    }

    /// El ajuste kurth.boosts cambió (kurth_set_settings): se ponen o se quitan todos a la vez.
    func ajusteCambio() {
        aplicando = Self.aplicar
        reponerEnTodas(ya: true)
        let aplica = Self.aplicar
        for boost in boosts.values where boost.encendido {
            _ = aplicarEnVivo(host: boost.host, css: aplica ? boost.css : "", recargarJS: boost.tieneJS)
        }
    }

    private func aplicarCambio(host: String, antes: KurthBoost?, despues: KurthBoost?, recargar: Bool) -> Resultado {
        programarEscritura()
        // Lo que de verdad corre en la página: apagado o con el ajuste general en false es "nada".
        func efectivo(_ b: KurthBoost?) -> (css: String, js: String) {
            guard Self.aplicar, let b, b.encendido else { return ("", "") }
            return (b.tieneCSS ? b.css : "", b.tieneJS ? b.js : "")
        }
        let (cssAntes, jsAntes) = efectivo(antes)
        let (cssDespues, jsDespues) = efectivo(despues)
        let recargarJS = recargar && jsAntes != jsDespues
        reponerEnTodas(ya: recargarJS)
        var resultado = Resultado(boost: despues)
        guard cssAntes != cssDespues || recargarJS else { return resultado }
        (resultado.enVivo, resultado.recargadas) = aplicarEnVivo(host: host, css: cssDespues, recargarJS: recargarJS)
        return resultado
    }

    /// Las vistas abiertas en ese host: recarga (JS) o cambia la <style> en su lugar (solo CSS).
    private func aplicarEnVivo(host: String, css: String, recargarJS: Bool) -> (enVivo: Int, recargadas: Int) {
        var enVivo = 0, recargadas = 0
        for vista in vistas.allObjects where KurthBoostsModelo.host(de: vista.url) == host {
            if recargarJS {
                vista.reload()
                recargadas += 1
                continue
            }
            enVivo += 1
            Task {
                do {
                    _ = try await vista.callAsyncJavaScript("return (\(KurthBoostsModelo.poner))(css)", arguments: ["css": css],
                                                            in: nil, contentWorld: KurthBoostsModelo.mundo)
                } catch {
                    Self.log.error("CSS en vivo en \(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return (enVivo, recargadas)
    }

    // MARK: - Disco

    private struct Archivo: Codable {
        var formatVersion = 1
        var boosts: [KurthBoost]
    }

    private func cargar() {
        guard let datos = try? Data(contentsOf: Self.archivo) else { return }
        let decodificador = JSONDecoder()
        decodificador.dateDecodingStrategy = .iso8601
        do {
            let archivo = try decodificador.decode(Archivo.self, from: datos)
            boosts = Dictionary(archivo.boosts.map { ($0.host, $0) }, uniquingKeysWith: { a, b in a.actualizado > b.actualizado ? a : b })
        } catch {
            // No se sobrescribe: el archivo se queda como está para arreglarlo a mano.
            Self.log.error("boosts.json no se pudo leer: \(error.localizedDescription, privacy: .public)")
            soloLectura = true
        }
    }

    /// Si el archivo existe pero no se pudo leer, no se escribe encima en esta ejecución.
    @ObservationIgnored private var soloLectura = false

    /// El editor de CSS guarda en cada tecla: al disco va medio segundo después de la última.
    private func programarEscritura() {
        escritura?.cancel()
        escritura = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.escribirYa()
        }
    }

    private func escribirYa() {
        escritura?.cancel()
        escritura = nil
        guard !soloLectura else { return }
        let codificador = JSONEncoder()
        codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
        codificador.dateEncodingStrategy = .iso8601
        let lista = boosts.values.sorted { $0.host < $1.host }
        guard let datos = try? codificador.encode(Archivo(boosts: lista)) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.archivo.deletingLastPathComponent(), withIntermediateDirectories: true)
            try datos.write(to: Self.archivo, options: .atomic)
        } catch {
            Self.log.error("boosts.json no se pudo escribir: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Describe una extensión

    /// Lo que va al agente además del pedido (no se pinta en el globo): cómo leer, escribir y
    /// aplicar el boost con kurth_boost. El pedido del usuario manda; esto solo le dice el camino.
    static func instrucciones(host: String) -> String {
        """
        [Boost] Kurth quiere personalizar \(host) con un Boost: CSS y JS propios que Nook aplica solo en \
        las páginas https de ese host exacto. Lo que pidió está arriba.
        1. Lee el boost actual con kurth_boost (action get, host "\(host)") y conserva lo que no choque.
        2. Mira la página (page_text, snapshot o run_js para dar con los selectores) y escribe lo mínimo: \
        CSS primero, JS solo si el CSS no alcanza.
        3. Guárdalo con kurth_boost (action set, host "\(host)", nombre de 2 a 4 palabras). El CSS se ve \
        al instante; si cambias el JS, las pestañas de ese host se recargan.
        4. Revisa con screenshot_tab que quedó y dile en una línea qué cambió.
        Selectores estables (id, atributos, aria, roles) antes que clases generadas; !important cuando \
        pelees con estilos del sitio. Nada que mande datos fuera del sitio ni que llene o envíe formularios.
        """
    }

    /// Abre el panel del agente en la ventana y le manda el pedido. El servicio arranca aquí mismo
    /// (no al aparecer el panel) para que el mensaje quede en espera y no se pierda.
    static func describir(_ pedido: String, host: String, pagina: PageSession?, en ventana: BrowserWindowState) {
        let limpio = pedido.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty, let agente = KurthAgentService.actual else { return }
        withAnimation(.easeInOut(duration: 0.2)) { ventana.isSidebarAIChatVisible = true }
        agente.arrancar()
        guard agente.aceptaMensajes else { return }
        let enlace = pagina.map {
            KurthACPResourceLink(uri: $0.url.absoluteString, name: $0.title.isEmpty ? host : $0.title,
                                 title: "Pestaña que el usuario está viendo en Nook")
        }
        agente.enviar("Boost · \(host): \(limpio)", pagina: enlace, oculto: instrucciones(host: host))
    }

    /// Si el botón de "Describe" puede mandar: con el agente apagado o en error también (lo arranca).
    static func agentePuedeRecibir() -> Bool {
        guard let agente = KurthAgentService.actual else { return false }
        switch agente.estado {
        case .apagado, .error: return !KurthRemoto.shared.encendido || agente.aceptaMensajes
        default: return agente.aceptaMensajes
        }
    }

    // MARK: - MCP

    static let herramienta = AIToolDefinition(
        name: "kurth_boost",
        description: """
        Boosts por sitio: CSS y JS propios que Nook aplica solo en las páginas https de un host exacto \
        (www.x.com no cubre x.com). action: list (todos, sin código), get (el de host, con código), set \
        (crea o cambia; lo que no mandes se conserva), delete. host: si falta, el de la pestaña activa. \
        El CSS va en una <style> al final del documento (gana los empates con la página; !important contra \
        estilos en línea) y en set se aplica en vivo. El JS es el cuerpo de una función async: corre en un \
        mundo aislado (ve el DOM, no las variables de la página) al terminar de cargar el HTML, una vez por \
        carga; en apps de una sola página usa MutationObserver. Se valida la sintaxis antes de guardar; si \
        el JS cambia, las pestañas de ese host se recargan (recargar: false lo evita). css o js vacíos \
        quitan esa parte; sin ninguna, el boost se borra.
        """,
        parameters: ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["list", "get", "set", "delete"]],
            "host": ["type": "string", "description": "Host exacto o una URL de él; sin él, la pestaña activa"],
            "css": ["type": "string"],
            "js": ["type": "string"],
            "nombre": ["type": "string", "description": "Nombre corto (2 a 4 palabras) de lo que hace"],
            "encendido": ["type": "boolean"],
            "recargar": ["type": "boolean", "description": "set: false para no recargar aunque cambie el JS"],
        ], "required": ["action"]]
    )

    /// nil si no es kurth_boost.
    static func llamar(_ nombre: String, _ args: [String: Any], window: BrowserWindowState, tabs: TabsController) -> [String: Any]? {
        guard nombre == herramienta.name else { return nil }
        let tienda = shared
        let accion = args["action"] as? String ?? ""
        if accion == "list" {
            let filas = tienda.boosts.values.sorted { $0.host < $1.host }.map { b -> [String: Any] in
                ["host": b.host, "nombre": b.nombre, "encendido": b.encendido,
                 "css": b.css.utf8.count, "js": b.js.utf8.count,
                 "actualizado": ISO8601DateFormatter().string(from: b.actualizado)]
            }
            return KurthMCPTools.text(KurthMCPTools.json(["aplicar": aplicar, "boosts": filas]))
        }
        let host = (args["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? KurthBoostsModelo.host(de: tabs.selectedSession(in: window)?.url)
        guard let host else { return KurthMCPTools.text("Falta host (la pestaña activa no es https)", error: true) }
        do {
            switch accion {
            case "get":
                guard let h = KurthBoostsModelo.host(de: host) else { throw Problema.host(host) }
                guard let b = tienda.boosts[h] else { return KurthMCPTools.text("\(h) no tiene boost") }
                return KurthMCPTools.text(KurthMCPTools.json(fila(b)))
            case "set":
                let r = try tienda.guardar(host: host, css: args["css"] as? String, js: args["js"] as? String,
                                           nombre: args["nombre"] as? String, encendido: args["encendido"] as? Bool,
                                           recargar: args["recargar"] as? Bool ?? true)
                var salida: [String: Any] = ["enVivo": r.enVivo, "recargadas": r.recargadas, "aplicar": aplicar]
                salida["boost"] = r.boost.map(fila) ?? "sin CSS ni JS: borrado"
                return KurthMCPTools.text(KurthMCPTools.json(salida))
            case "delete":
                let r = try tienda.borrar(host: host)
                return KurthMCPTools.text("Borrado. Recargadas: \(r.recargadas); CSS quitado en vivo: \(r.enVivo)")
            default:
                return KurthMCPTools.text("action: list, get, set o delete", error: true)
            }
        } catch {
            return KurthMCPTools.text(error.localizedDescription, error: true)
        }
    }

    private static func fila(_ b: KurthBoost) -> [String: Any] {
        ["host": b.host, "nombre": b.nombre, "encendido": b.encendido, "css": b.css, "js": b.js,
         "actualizado": ISO8601DateFormatter().string(from: b.actualizado)]
    }
}
