// Licensed under GPL-3.0. See LICENSE.
//
//  KurthPageState.swift
//  Nook (rama kurth)
//
//  Lo que la barra necesita saber de cada página: si está hasta arriba y de qué color es su
//  parte alta. Viene de WebKit, no de JavaScript ni de un timer:
//  - Scroll: WebKit llama `_updateScrollGeometryWithContentOffset:contentSize:` cada vez que
//    cambia la posición si se le pide con `_setNeedsScrollGeometryUpdates:` (es lo que usa el
//    WebView de SwiftUI para onScrollGeometryChange). Lo interceptamos en FocusableWKWebView.
//  - Color: `_sampledPageTopColor`, el color que WebKit muestrea de la parte alta de la página
//    y que Safari usa para su barra. Se enciende en la configuración (KurthLaunch.swift).
//  Todo se llama solo si WebKit lo tiene; si no, la barra usa themeColor/underPageBackgroundColor.
//

import AppKit
import Observation
import ObjectiveC
import WebKit

@MainActor
@Observable
final class KurthPageState {
    /// Puntos desplazados desde arriba.
    private(set) var scrollY: CGFloat = 0
    /// Color de la parte alta de la página, o nil mientras WebKit no lo tenga.
    private(set) var topColor: NSColor?
    /// Color del encabezado fijo pegado arriba (YouTube, Gmail), o nil si la página no tiene.
    /// Es lo que WebKit usa para su extensión de color sobre la franja tapada.
    private(set) var topHeaderColor: NSColor?
    /// El mismo encabezado, visto por el script de la página (KurthCopilot.js). WebKit solo lo
    /// detecta si va de orilla a orilla; el de Robb Report deja 76 pt de cada lado y la página se
    /// asomaba entre la barra y él (Kurth, 25 sep). Con este, la barra pinta la franja ella misma.
    private(set) var scriptHeaderColor: NSColor?

    /// Lo que el script ve hasta arriba de la página (KurthCopilot.js, `arriba`). Solo cuenta si
    /// WebKit no muestrea nada ni hay theme-color: Google Ads tiene html y body transparentes y su
    /// gris en una capa absoluta, y sin esto la barra caía al blanco del lienzo (Kurth, 28 sep).
    private(set) var scriptTopColor: NSColor?

    func setScriptTopColor(_ color: NSColor?, webView: WKWebView) {
        guard color != scriptTopColor else { return }
        scriptTopColor = color
        refreshColor(from: webView)
    }

    var hasTopHeader: Bool { topHeaderColor != nil || scriptHeaderColor != nil }

    func setScriptHeaderColor(_ color: NSColor?) {
        if color != scriptHeaderColor { scriptHeaderColor = color }
    }

    var isAtTop: Bool { scrollY <= 1 }

    private static var key: UInt8 = 0

    static func of(_ webView: WKWebView) -> KurthPageState {
        if let state = objc_getAssociatedObject(webView, &key) as? KurthPageState { return state }
        let state = KurthPageState()
        objc_setAssociatedObject(webView, &key, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        state.refreshColor(from: webView)
        state.colorWatcher = KurthColorWatcher(webView) { [weak state, weak webView] in
            guard let state, let webView else { return }
            state.refreshColor(from: webView)
        }
        return state
    }

    /// Sin esto el color solo se volvía a leer con el scroll del documento, y las apps que desplazan
    /// una caja interna (Google Ads: el documento mide lo mismo que la ventana) se quedaban con el
    /// blanco de mientras cargaban (Kurth, 28 sep).
    private var colorWatcher: KurthColorWatcher?

    fileprivate func update(offset: CGPoint, webView: WKWebView) {
        // Crudo, con el negativo del rebote: es la distancia de jalar para recargar.
        KurthJalarParaRecargar.desplazamiento(offset.y, en: webView)
        let y = max(0, offset.y)
        if abs(y - scrollY) >= 0.5 { scrollY = y }
        refreshColor(from: webView)
    }

    func refreshColor(from webView: WKWebView) {
        let sampled = Self.privateColor(webView, "_sampledPageTopColor")
        let color = sampled ?? webView.themeColor ?? scriptTopColor ?? webView.underPageBackgroundColor
        if color != topColor { topColor = color }
        let header = Self.privateColor(webView, "_sampledTopFixedPositionContentColor")
        if header != topHeaderColor { topHeaderColor = header }
        applyUnderPageColor(sampled, to: webView)
    }

    // MARK: - Hueco del rebote elástico

    /// Color que WebKit pinta en el hueco al jalar hasta arriba. Nook lo fija con un píxel suyo
    /// que con la barra encima salía blanco (#FFFFFF contra #FBF8F6 en Craft, medido el 23 sep):
    /// se veía una franja blanca bajo la barra. Lo igualamos al color de arriba de la página, el
    /// mismo que usa la barra, y si alguien lo vuelve a cambiar lo regresamos.
    private var wantedUnderPage: NSColor?
    private var underPageObservation: NSKeyValueObservation?

    private func applyUnderPageColor(_ color: NSColor?, to webView: WKWebView) {
        guard let color else { return }
        wantedUnderPage = color
        if webView.underPageBackgroundColor != color { webView.underPageBackgroundColor = color }
        guard underPageObservation == nil else { return }
        underPageObservation = webView.observe(\.underPageBackgroundColor) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self, let wanted = self.wantedUnderPage,
                      webView.underPageBackgroundColor != wanted else { return }
                webView.underPageBackgroundColor = wanted
            }
        }
    }

    private static func privateColor(_ webView: WKWebView, _ name: String) -> NSColor? {
        let selector = NSSelectorFromString(name)
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSColor
    }

    // MARK: - Enganche con WebKit

    private static var installed = false
    private static var observedKey: UInt8 = 0

    /// Pide a WebKit los avisos de scroll para esta página e intercepta el aviso una sola vez
    /// para toda la clase.
    static func attach(to webView: FocusableWKWebView) {
        installOnce()
        KurthSenalar.instalar(en: webView) // script del copiloto y canal de marcas en cada página
        KurthPasswords.instalar(en: webView)
        KurthAutoconsent.instalar(en: webView)
        KurthBoosts.instalar(en: webView)
        KurthWorkflows.instalar(en: webView)
        guard objc_getAssociatedObject(webView, &observedKey) == nil else { return }
        objc_setAssociatedObject(webView, &observedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let selector = NSSelectorFromString("_setNeedsScrollGeometryUpdates:")
        guard webView.responds(to: selector), let imp = webView.method(for: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(imp, to: Setter.self)(webView, selector, true)
        _ = of(webView)
    }

    private static func installOnce() {
        guard !installed else { return }
        installed = true
        let selector = NSSelectorFromString("_updateScrollGeometryWithContentOffset:contentSize:")
        guard let parent = class_getInstanceMethod(WKWebView.self, selector) else { return }
        typealias Update = @convention(c) (AnyObject, Selector, CGPoint, CGSize) -> Void
        let original = unsafeBitCast(method_getImplementation(parent), to: Update.self)
        let block: @convention(block) (AnyObject, CGPoint, CGSize) -> Void = { object, offset, size in
            original(object, selector, offset, size)
            guard let webView = object as? WKWebView else { return }
            MainActor.assumeIsolated {
                KurthPageState.of(webView).update(offset: offset, webView: webView)
            }
        }
        // En la subclase: WKWebView queda intacto y solo nuestras páginas avisan.
        class_addMethod(FocusableWKWebView.self, selector, imp_implementationWithBlock(block), method_getTypeEncoding(parent))
    }
}

/// Avisa cuando WebKit cambia los colores que usa la barra. `_sampledPageTopColor` y
/// `_sampledTopFixedPositionContentColor` son SPI pero cumplen KVO (Safari los observa así); se
/// observan por nombre y solo si el WebKit instalado los tiene.
private final class KurthColorWatcher: NSObject {
    private static let keys = ["_sampledPageTopColor", "_sampledTopFixedPositionContentColor", "themeColor"]
    private weak var webView: WKWebView?
    private var observed: [String] = []
    private let onChange: @MainActor () -> Void

    init(_ webView: WKWebView, onChange: @escaping @MainActor () -> Void) {
        self.webView = webView
        self.onChange = onChange
        super.init()
        for key in Self.keys where webView.responds(to: NSSelectorFromString(key)) {
            webView.addObserver(self, forKeyPath: key, options: [], context: nil)
            observed.append(key)
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let onChange = self.onChange
        if Thread.isMainThread {
            MainActor.assumeIsolated { onChange() }
        } else {
            DispatchQueue.main.async { onChange() }
        }
    }

    deinit {
        // Vive tanto como el WKWebView (va colgado de él): si ya no está, desde macOS 10.13 KVO no
        // exige quitar el observador de un objeto que se destruye.
        guard let webView else { return }
        for key in observed { webView.removeObserver(self, forKeyPath: key) }
    }
}
