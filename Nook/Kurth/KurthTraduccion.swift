// Licensed under GPL-3.0. See LICENSE.
//
//  KurthTraduccion.swift
//  Nook (rama kurth)
//
//  Traducir la página en el dispositivo con el framework Translation de Apple (sin mandar nada a
//  un servidor). Kurth lo pidió en el plan del 26 sep (punto 9); Safari lo trae y Nook no.
//
//  Piezas:
//  - KurthTraduccion.js encuentra el texto por bloques, lo entrega en lotes y lo reinyecta.
//  - KurthTraduccionLotes.swift arma las peticiones y reparte las respuestas a cada nodo.
//  - Aquí: detectar el idioma al terminar de cargar, la sesión de traducción, el estado por
//    pestaña que pinta el botón de la cápsula (KurthTraduccionControl.swift) y la herramienta MCP.
//
//  La sesión. `TranslationSession(installedSource:target:)` (macOS 26.0) se crea fuera de
//  cualquier vista, pero solo sirve si el par de idiomas ya está descargado. Descargarlo pide la
//  hoja del sistema, y esa solo la da una sesión nacida de `.translationTask` en una vista de
//  SwiftUI (en el SDK de macOS 27 no hay otra API pública). Por eso: si falta el par, una vista
//  oculta de cada ventana (KurthTraduccionAncla) pide la descarga con prepareTranslation() y suelta
//  su sesión; la traducción de verdad siempre va por la sesión directa, que vive lo que la app y no
//  depende de que ninguna vista siga en pantalla.
//
//  Estrategia: .lowLatency (26.4+). El default del sistema en 27 es .highFidelity; una página
//  manda cientos de fragmentos y aquí manda la velocidad (prioridad 1 de Nook). Si la calidad no
//  alcanza, es cambiar `estrategiaRapida`.
//

import AppKit
import NaturalLanguage
import ObjectiveC
import Observation
import Translation
import WebKit
import NookWeb
import os

// MARK: - Motor: sesiones, destino y disponibilidad

@MainActor
final class KurthTraductor {
    static let shared = KurthTraductor()
    fileprivate static let log = Logger(subsystem: "com.gstudios.nook", category: "KurthTraduccion")
    static let estrategiaRapida = true

    private var sesiones: [String: TranslationSession] = [:]
    private var destinoResuelto: Locale.Language?
    /// Una traducción a la vez en toda la app: no está documentado que una sesión aguante
    /// peticiones concurrentes, y el modelo corre en el mismo acelerador de todos modos.
    private var ultima: Task<Void, Never>?

    private lazy var disponibilidad: LanguageAvailability = {
        if Self.estrategiaRapida, #available(macOS 26.4, *) { return LanguageAvailability(preferredStrategy: .lowLatency) }
        return LanguageAvailability()
    }()

    /// El idioma del sistema de Kurth, en la variante que Translation soporta. El sistema dice
    /// es-419 con región MX; Translation trae es-MX, es (España) y es-US: gana la de la región.
    func destino() async -> Locale.Language {
        if let destinoResuelto { return destinoResuelto }
        let preferido = Locale.Language(identifier: Locale.preferredLanguages.first ?? "es")
        let soportados = await disponibilidad.supportedLanguages
        let mismos = soportados.filter { $0.languageCode == preferido.languageCode }
        let region = Locale.current.region
        let elegido = mismos.first { region != nil && $0.region == region }
            ?? mismos.first { preferido.region != nil && $0.region == preferido.region }
            ?? mismos.first
            ?? preferido
        destinoResuelto = elegido
        return elegido
    }

    func estado(de origen: Locale.Language) async -> LanguageAvailability.Status {
        await disponibilidad.status(from: origen, to: await destino())
    }

    /// Sesión lista para traducir de `origen` al idioma del sistema. Si falta el par, pide la
    /// descarga en la ventana `ventanaID` y espera a que el usuario la acepte.
    func sesion(de origen: Locale.Language, ventanaID: UUID?) async throws -> TranslationSession {
        let destino = await destino()
        let clave = origen.minimalIdentifier + ">" + destino.minimalIdentifier
        if let s = sesiones[clave] { return s }
        switch await disponibilidad.status(from: origen, to: destino) {
        case .unsupported:
            throw KurthCopilotError("Apple no traduce de \(Self.nombre(origen)) a \(Self.nombre(destino)).")
        case .supported:
            guard let ventanaID else { throw KurthCopilotError("Falta descargar \(Self.nombre(origen)) y no hay ventana donde pedirlo.") }
            try await KurthTraduccionDescarga.shared.pedir(origen, destino, ventanaID: ventanaID)
        default:
            break
        }
        let s = Self.nuevaSesion(origen, destino)
        sesiones[clave] = s
        return s
    }

    private static func nuevaSesion(_ origen: Locale.Language, _ destino: Locale.Language) -> TranslationSession {
        if estrategiaRapida, #available(macOS 26.4, *) {
            return TranslationSession(installedSource: origen, target: destino, preferredStrategy: .lowLatency)
        }
        return TranslationSession(installedSource: origen, target: destino)
    }

    static func configuracion(_ origen: Locale.Language, _ destino: Locale.Language) -> TranslationSession.Configuration {
        if estrategiaRapida, #available(macOS 26.4, *) {
            return TranslationSession.Configuration(source: origen, target: destino, preferredStrategy: .lowLatency)
        }
        return TranslationSession.Configuration(source: origen, target: destino)
    }

    struct Lote {
        var resultados: [Int: [String?]] = [:]
        var fallidas: [Int] = []
        var atribuidas = 0
        var porPartes = 0
        var segundaVuelta = 0
    }

    /// Traduce un lote de unidades: primero atribuidas, luego por partes las que regresaron sin
    /// marcas. Una unidad que el modelo no pudo traducir queda en `fallidas` (no se reintenta).
    func traducir(_ unidades: [KurthUnidadDeTraduccion], con sesion: TranslationSession) async throws -> Lote {
        let respuestas = try await enSerie { try await Self.robusto(KurthLotes.peticiones(unidades, atribuidas: true), sesion) }
        var reparto = KurthLotes.repartir(unidades, respuestas, atribuidas: true)
        var lote = Lote()
        if !reparto.sinRepartir.isEmpty {
            lote.segundaVuelta = reparto.sinRepartir.count
            let pendientes = reparto.sinRepartir
            let segunda = try await enSerie { try await Self.robusto(pendientes.flatMap(KurthLotes.porPartes), sesion) }
            let r2 = KurthLotes.repartir(pendientes, segunda, atribuidas: false)
            reparto.resultados.merge(r2.resultados) { $1 }
            reparto.porPartes += r2.porPartes
        }
        lote.resultados = reparto.resultados
        lote.atribuidas = reparto.atribuidas
        lote.porPartes = reparto.porPartes
        lote.fallidas = unidades.map(\.id).filter { reparto.resultados[$0] == nil }
        return lote
    }

    private func enSerie<T: Sendable>(_ trabajo: @escaping @MainActor () async throws -> T) async throws -> T {
        let previa = ultima
        let tarea = Task { @MainActor in
            _ = await previa?.value
            return try await trabajo()
        }
        ultima = Task { _ = try? await tarea.value }
        return try await tarea.value
    }

    /// Todo el lote en una llamada; si falla, una por una para no perder el lote entero por un
    /// fragmento raro. Si el par se desinstaló, se suelta la sesión y el error sube.
    private static func robusto(_ peticiones: [TranslationSession.Request], _ sesion: TranslationSession) async throws -> [TranslationSession.Response] {
        guard !peticiones.isEmpty else { return [] }
        do {
            return try await sesion.translations(from: peticiones)
        } catch {
            if error is CancellationError { throw error }
            if TranslationError.notInstalled ~= error {
                shared.sesiones = shared.sesiones.filter { $0.value !== sesion }
                throw error
            }
            log.notice("lote falló (\(peticiones.count)): \(error.localizedDescription, privacy: .public); uno por uno")
            var fuera: [TranslationSession.Response] = []
            var seguidas = 0
            for p in peticiones {
                if let r = try? await sesion.translations(from: [p]) { fuera += r; seguidas = 0 }
                else { seguidas += 1; if seguidas >= 3 && fuera.isEmpty { break } }
            }
            return fuera
        }
    }

    static func nombre(_ l: Locale.Language) -> String {
        Locale.current.localizedString(forLanguageCode: l.languageCode?.identifier ?? "") ?? l.minimalIdentifier
    }
}

// MARK: - Descarga del par de idiomas (la pide la vista oculta de la ventana)

@MainActor
@Observable
final class KurthTraduccionDescarga {
    static let shared = KurthTraduccionDescarga()

    struct Peticion: Equatable {
        let id: UUID
        let ventanaID: UUID
        let config: TranslationSession.Configuration
    }

    private(set) var peticion: Peticion?
    @ObservationIgnored private var espera: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var tomada = false

    func pedir(_ origen: Locale.Language, _ destino: Locale.Language, ventanaID: UUID) async throws {
        guard peticion == nil else { throw KurthCopilotError("Ya hay una descarga de idiomas pendiente.") }
        let p = Peticion(id: UUID(), ventanaID: ventanaID, config: KurthTraductor.configuracion(origen, destino))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            espera = c
            tomada = false
            peticion = p
            // Si ninguna ventana la toma (la barra no está montada), no se queda colgada.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.peticion?.id == p.id, !self.tomada else { return }
                self.terminar(p.id, KurthCopilotError("No hay una ventana a la vista donde pedir la descarga del idioma."))
            }
        }
    }

    func tomar(_ id: UUID) { if peticion?.id == id { tomada = true } }

    func terminar(_ id: UUID, _ error: Error?) {
        guard peticion?.id == id, let c = espera else { return }
        espera = nil
        peticion = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}

// MARK: - Estado por pestaña

@MainActor
@Observable
final class KurthTraduccion {
    enum Estado: Equatable {
        case sinDetectar
        /// La página ya está en un idioma del sistema.
        case mismoIdioma
        /// Translation no traduce de ese idioma.
        case sinSoporte
        case ofrecida
        case traduciendo
        case traducida
        case error(String)
    }

    static let ajuste = "kurth.translateOffer"
    static var ofrecer: Bool { UserDefaults.standard.object(forKey: ajuste) as? Bool ?? true }

    private(set) var estado: Estado = .sinDetectar
    private(set) var idioma: Locale.Language?
    private(set) var confianza: Double = 0
    /// El idioma que se tradujo en esta pestaña: las páginas siguientes en ese mismo idioma se
    /// traducen solas, como Safari y Chrome. "Ver original" lo apaga.
    private(set) var pegajosa: Locale.Language?

    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored private(set) var urlDetectada: URL?
    @ObservationIgnored private var generacion = 0
    /// La generación cuyo bucle de lotes está corriendo. Por generación y no un Bool: si la página
    /// navega con un lote en vuelo, el bucle viejo no debe impedir que arranque el de la nueva.
    @ObservationIgnored private var bombeandoEn: Int?
    @ObservationIgnored private var hayMas = false
    @ObservationIgnored private var sesion: TranslationSession?
    @ObservationIgnored private var ventanaID: UUID?
    @ObservationIgnored private(set) var cuentas = (lotes: 0, atribuidas: 0, porPartes: 0, segundaVuelta: 0, fallidas: 0, ms: 0.0)
    @ObservationIgnored private(set) var disponibilidad: LanguageAvailability.Status?

    private static var clave: UInt8 = 0

    static func of(_ webView: WKWebView) -> KurthTraduccion {
        if let t = objc_getAssociatedObject(webView, &clave) as? KurthTraduccion { return t }
        let t = KurthTraduccion()
        t.webView = webView
        objc_setAssociatedObject(webView, &clave, t, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return t
    }

    /// El botón aparece si hay algo que ofrecer o que deshacer.
    func muestraControl(ofrecer: Bool) -> Bool {
        switch estado {
        case .ofrecida: return ofrecer
        case .traduciendo, .traducida, .error: return true
        default: return false
        }
    }

    // MARK: Ciclo de la página

    /// La pestaña empezó a cargar otro documento: su mundo de JavaScript se va con él.
    func nuevaCarga() {
        generacion += 1
        estado = .sinDetectar
        idioma = nil
        urlDetectada = nil
    }

    /// Al terminar de cargar (o al cambiar de URL dentro de la misma página).
    func detectar(ventanaID: UUID?, forzar: Bool = false) async {
        guard let webView, let url = webView.url, ["http", "https", "file"].contains(url.scheme ?? "") else { return }
        if let ventanaID { self.ventanaID = ventanaID }
        if !forzar, url == urlDetectada, estado != .sinDetectar { return }
        let g = generacion
        do {
            try await asegurarScript()
            // Navegación dentro de la misma página con la traducción puesta: sigue puesta.
            if let e = try await js("return window.__kurthTrad.estado()") as? [String: Any], e["activa"] as? Bool == true {
                urlDetectada = url
                if estado != .traduciendo { estado = .traducida }
                return
            }
            var muestra = try await js("return window.__kurthTrad.muestra(2000)") as? [String: Any] ?? [:]
            // Una SPA puede terminar de cargar con la página vacía: se mira otra vez un poco después.
            if (muestra["texto"] as? String ?? "").count < 200 {
                try await Task.sleep(for: .milliseconds(1500))
                guard g == generacion else { return }
                muestra = try await js("return window.__kurthTrad.muestra(2000)") as? [String: Any] ?? muestra
            }
            guard g == generacion else { return }
            urlDetectada = url
            let (lengua, seguridad) = Self.reconocer(texto: muestra["texto"] as? String ?? "", declarado: muestra["lang"] as? String ?? "")
            idioma = lengua
            confianza = seguridad
            guard let lengua else { estado = .sinDetectar; return }
            if Self.esDelSistema(lengua) { estado = .mismoIdioma; return }
            let status = await KurthTraductor.shared.estado(de: lengua)
            guard g == generacion else { return }
            disponibilidad = status
            if status == .unsupported { estado = .sinSoporte; return }
            estado = .ofrecida
            if let pegajosa, pegajosa.languageCode == lengua.languageCode, status == .installed {
                await traducir(ventanaID: self.ventanaID)
            }
        } catch {
            KurthTraductor.log.notice("detectar: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// NLLanguageRecognizer sobre el texto; el lang del documento solo desempata o suple cuando
    /// hay poco texto (muchas plantillas dicen lang="en" aunque la página esté en otro idioma).
    static func reconocer(texto: String, declarado: String) -> (Locale.Language?, Double) {
        let declarada = declarado.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
        let r = NLLanguageRecognizer()
        r.processString(texto)
        let hipotesis = r.languageHypotheses(withMaximum: 1).first
        var codigo = hipotesis.map { $0.key.rawValue }
        var seguridad = hipotesis?.value ?? 0
        if codigo == "und" { codigo = nil }
        if texto.count < 60 || seguridad < 0.5 {
            if !declarada.isEmpty { codigo = declarado; seguridad = max(seguridad, 0.5) }
            else if texto.count < 20 { codigo = nil }
        }
        return (codigo.map { Locale.Language(identifier: $0) }, seguridad)
    }

    static func esDelSistema(_ l: Locale.Language) -> Bool {
        Locale.preferredLanguages.contains { Locale.Language(identifier: $0).languageCode == l.languageCode }
    }

    // MARK: Traducir y ver original

    func traducir(ventanaID: UUID?) async {
        guard webView != nil else { return }
        if let ventanaID { self.ventanaID = ventanaID }
        if idioma == nil { await detectar(ventanaID: ventanaID, forzar: true) }
        guard let origen = idioma else { estado = .error("No reconocí el idioma de la página."); return }
        if estado == .traduciendo || estado == .traducida { return }
        if Self.esDelSistema(origen) { estado = .mismoIdioma; return }
        generacion += 1
        let g = generacion
        estado = .traduciendo
        do {
            let s = try await KurthTraductor.shared.sesion(de: origen, ventanaID: self.ventanaID)
            guard g == generacion, let webView else { return }
            disponibilidad = .installed
            sesion = s
            Self.registrarCanal(webView)
            try await asegurarScript()
            hayMas = false
            _ = try await js("return window.__kurthTrad.activar()")
            pegajosa = origen
            // El IntersectionObserver avisa en el siguiente cuadro; se le espera un poco para que
            // el giro del botón dure lo que dura la primera tanda.
            let limite = Date().addingTimeInterval(1.5)
            while !hayMas, Date() < limite, g == generacion { try await Task.sleep(for: .milliseconds(40)) }
            try await bombear(g)
            if g == generacion { estado = .traducida }
        } catch {
            guard g == generacion else { return }
            if error is CancellationError {
                estado = .ofrecida
            } else {
                KurthTraductor.log.error("traducir: \(error.localizedDescription, privacy: .public)")
                estado = .error(error.localizedDescription)
            }
        }
    }

    func verOriginal() async {
        generacion += 1
        pegajosa = nil
        _ = try? await js("return window.__kurthTrad ? window.__kurthTrad.original() : 0")
        estado = idioma == nil ? .sinDetectar : .ofrecida
    }

    /// Jala lotes de la página hasta vaciar la cola. Uno a la vez por pestaña: si llega otro aviso
    /// mientras corre, la vuelta en curso lo recoge (hayMas).
    private func bombear(_ g: Int) async throws {
        guard bombeandoEn != g else { hayMas = true; return }
        bombeandoEn = g
        defer { if bombeandoEn == g { bombeandoEn = nil } }
        while g == generacion, let sesion {
            let crudo = try await js("return window.__kurthTrad.tomar(40)") as? [[String: Any]] ?? []
            if crudo.isEmpty {
                if hayMas { hayMas = false; continue }
                break
            }
            hayMas = false
            let unidades = crudo.compactMap(KurthUnidadDeTraduccion.init)
            let inicio = Date()
            let lote = try await KurthTraductor.shared.traducir(unidades, con: sesion)
            guard g == generacion else { return }
            cuentas.lotes += 1
            cuentas.atribuidas += lote.atribuidas
            cuentas.porPartes += lote.porPartes
            cuentas.segundaVuelta += lote.segundaVuelta
            cuentas.fallidas += lote.fallidas.count
            cuentas.ms = Date().timeIntervalSince(inicio) * 1000
            _ = try await js("return window.__kurthTrad.aplicar(r)", ["r": KurthLotes.paraJS(lote.resultados)])
            if !lote.fallidas.isEmpty { _ = try? await js("return window.__kurthTrad.fallo(ids)", ["ids": lote.fallidas]) }
        }
    }

    /// Aviso de la página: hay texto nuevo a la vista (scroll, contenido que llegó).
    fileprivate func hayPendientes() {
        hayMas = true
        guard estado == .traducida, bombeandoEn != generacion else { return }
        let g = generacion
        Task { @MainActor in
            do { try await self.bombear(g) }
            catch { KurthTraductor.log.notice("bombear: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Para el MCP con una pestaña que no está a la vista: nadie le avisó de sus cargas.
    func sincronizar(ventanaID: UUID?) async {
        guard let webView else { return }
        if webView.url != urlDetectada { nuevaCarga() }
        let activa = (try? await js("return window.__kurthTrad ? window.__kurthTrad.estado().activa : false")) as? Bool ?? false
        if !activa, estado == .traducida { estado = .ofrecida }
        await detectar(ventanaID: ventanaID)
    }

    func informe() async -> [String: Any] {
        var d: [String: Any] = [
            "url": webView?.url?.absoluteString ?? "",
            "ofrecerAjuste": Self.ofrecer,
            "confianza": (confianza * 100).rounded() / 100,
            "destino": (await KurthTraductor.shared.destino()).minimalIdentifier,
            "rutas": ["lotes": cuentas.lotes, "atribuidas": cuentas.atribuidas, "porPartes": cuentas.porPartes,
                      "segundaVuelta": cuentas.segundaVuelta, "fallidas": cuentas.fallidas,
                      "msUltimoLote": Int(cuentas.ms)],
        ]
        switch estado {
        case .sinDetectar: d["estado"] = "sin detectar"
        case .mismoIdioma: d["estado"] = "ya está en el idioma del sistema"
        case .sinSoporte: d["estado"] = "idioma sin soporte en Translation"
        case .ofrecida: d["estado"] = "ofrecida"
        case .traduciendo: d["estado"] = "traduciendo"
        case .traducida: d["estado"] = "traducida"
        case .error(let m): d["estado"] = "error"; d["error"] = m
        }
        d["traducida"] = estado == .traducida
        if let idioma { d["idioma"] = idioma.minimalIdentifier; d["idiomaNombre"] = KurthTraductor.nombre(idioma) }
        if let pegajosa { d["traducirSiguientes"] = pegajosa.minimalIdentifier }
        switch disponibilidad {
        case .installed: d["par"] = "instalado"
        case .supported: d["par"] = "sin descargar (pedirá la hoja del sistema)"
        case .unsupported: d["par"] = "sin soporte"
        default: break
        }
        if let e = (try? await js("return window.__kurthTrad ? window.__kurthTrad.estado() : null")) as? [String: Any] {
            d["pagina"] = e
        }
        return d
    }

    // MARK: JavaScript

    private static let fuente: String? = {
        guard let ruta = Bundle.main.path(forResource: "KurthTraduccion", ofType: "js"),
              let js = try? String(contentsOfFile: ruta, encoding: .utf8), !js.isEmpty else { return nil }
        return js
    }()

    /// El script se pone al primer uso en cada documento, no en todas las páginas por adelantado:
    /// una página que nunca se detecta ni se traduce no paga nada.
    private func asegurarScript() async throws {
        if try await js("return typeof window.__kurthTrad") as? String == "object" { return }
        guard let fuente = Self.fuente else { throw KurthCopilotError("Falta KurthTraduccion.js en la app.") }
        _ = try await js(fuente + "\nreturn true")
    }

    private func js(_ codigo: String, _ args: [String: Any] = [:]) async throws -> Any? {
        guard let webView else { throw KurthCopilotError("La pestaña ya no tiene vista web.") }
        do {
            return try await webView.callAsyncJavaScript(codigo, arguments: args, in: nil, contentWorld: KurthCopilot.mundo)
        } catch {
            let ns = error as NSError
            throw KurthCopilotError(ns.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
        }
    }

    // MARK: Canal de avisos (página → Swift)

    private static let canal = Canal()
    private static let conCanal = NSHashTable<WKUserContentController>.weakObjects()

    /// En el mundo aislado y solo del marco principal: una página no puede fingir avisos (y aunque
    /// pudiera, un aviso solo hace que Swift pregunte si hay texto pendiente).
    static func registrarCanal(_ webView: WKWebView) {
        let controlador = webView.configuration.userContentController
        guard !conCanal.contains(controlador) else { return }
        conCanal.add(controlador)
        controlador.add(canal, contentWorld: KurthCopilot.mundo, name: "kurthTraduccion")
    }

    private final class Canal: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive mensaje: WKScriptMessage) {
            guard mensaje.frameInfo.isMainFrame, let webView = mensaje.webView else { return }
            MainActor.assumeIsolated { KurthTraduccion.of(webView).hayPendientes() }
        }
    }

    // MARK: - MCP

    static let herramienta = AIToolDefinition(
        name: "kurth_translate",
        description: "Traducción de la página en el dispositivo (framework Translation de Apple). status: idioma detectado, si la página está traducida, si el par de idiomas está instalado y cuántos fragmentos salieron por la ruta atribuida (frase con links) o por partes. translate: traduce (si falta el par, pide la hoja de descarga del sistema en la ventana activa y espera hasta 90 s). original: regresa el texto original. Sin tabId, la pestaña activa.",
        parameters: ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["status", "translate", "original"]],
            "tabId": ["type": "string", "description": "UUID de la pestaña (list_tabs); sin él, la activa"],
        ], "required": ["action"]]
    )

    /// nil si la herramienta no es esta.
    static func llamar(_ nombre: String, _ args: [String: Any], browserManager bm: BrowserManager) async -> [String: Any]? {
        guard nombre == herramienta.name else { return nil }
        let registro = bm.windowRegistry
        let activa = registro?.activeWindow ?? registro?.windows.values.first
        let itemID: UUID
        if let texto = args["tabId"] as? String, !texto.isEmpty {
            guard let id = UUID(uuidString: texto) else { return KurthMCPTools.text("tabId no válido: \(texto)", error: true) }
            itemID = id
        } else {
            guard let id = activa?.selectedItemID else { return KurthMCPTools.text("No hay pestaña activa.", error: true) }
            itemID = id
        }
        let ventana = registro.flatMap { r in r.windows.values.first { $0.selectedItemID == itemID } }
        guard let webView = ventana.flatMap({ bm.getWebView(for: itemID, in: $0.id) }) ?? bm.tabs.session(for: itemID)?.webView else {
            return KurthMCPTools.text("La pestaña \(itemID) no está cargada. Selecciónala o ábrela con open_tab.", error: true)
        }
        let t = of(webView)
        let ventanaID = ventana?.id ?? activa?.id
        switch args["action"] as? String {
        case "translate":
            await t.sincronizar(ventanaID: ventanaID)
            // Carrera: la traducción o 90 s (la hoja de descarga espera al usuario). Si gana el
            // reloj, la traducción sigue sola y el informe dice "traduciendo".
            let tarea = Task { await t.traducir(ventanaID: ventanaID) }
            await withTaskGroup(of: Void.self) { grupo in
                grupo.addTask { await tarea.value }
                grupo.addTask { try? await Task.sleep(for: .seconds(90)) }
                await grupo.next()
                grupo.cancelAll()
            }
        case "original":
            await t.verOriginal()
        case "status":
            await t.sincronizar(ventanaID: ventanaID)
        default:
            return KurthMCPTools.text("action: status, translate u original", error: true)
        }
        var informe = await t.informe()
        informe["tabId"] = itemID.uuidString
        return KurthMCPTools.text(KurthMCPTools.json(informe))
    }
}
