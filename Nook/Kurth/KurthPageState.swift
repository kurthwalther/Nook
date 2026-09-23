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

    var isAtTop: Bool { scrollY <= 1 }

    private static var key: UInt8 = 0

    static func of(_ webView: WKWebView) -> KurthPageState {
        if let state = objc_getAssociatedObject(webView, &key) as? KurthPageState { return state }
        let state = KurthPageState()
        objc_setAssociatedObject(webView, &key, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        state.refreshColor(from: webView)
        return state
    }

    fileprivate func update(offset: CGPoint, webView: WKWebView) {
        let y = max(0, offset.y)
        if abs(y - scrollY) >= 0.5 { scrollY = y }
        refreshColor(from: webView)
    }

    func refreshColor(from webView: WKWebView) {
        let color = Self.sampledTopColor(webView) ?? webView.themeColor ?? webView.underPageBackgroundColor
        if color != topColor { topColor = color }
    }

    private static func sampledTopColor(_ webView: WKWebView) -> NSColor? {
        let selector = NSSelectorFromString("_sampledPageTopColor")
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
