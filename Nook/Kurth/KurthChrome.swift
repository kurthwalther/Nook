// Licensed under GPL-3.0. See LICENSE.
//
//  KurthChrome.swift
//  Nook (rama kurth)
//
//  Capa propia sobre Nook. Todo lo de Nook/Kurth/ es nuestro; los ganchos en archivos de
//  upstream llevan un comentario "kurth:" para encontrarlos al rebasar.
//

import AppKit
import SwiftUI
import WebKit

enum KurthChrome {
    /// La barra superior flota sobre la página, con blur, en lugar de ir apilada encima de ella.
    static let floatingTopBar = true

    static let topBarHeight: CGFloat = 40
    /// Desvanecido bajo la barra: el blur se apaga poco a poco en vez de cortar con una línea.
    static let topBarFade: CGFloat = 12

    /// Rectángulo de la barra por ventana, en coordenadas de SwiftUI (origen arriba a la izquierda).
    @MainActor private static var barRects: [ObjectIdentifier: CGRect] = [:]

    @MainActor static func setBarRect(_ rect: CGRect?, in window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard barRects[key] != rect else { return }
        barRects[key] = rect
        // Las páginas vuelven a calcular cuánto les tapa la barra.
        window.contentView.map(markWebViewsForLayout)
    }

    /// Le dice a WebKit cuántos puntos de arriba tapa la barra: el contenido fijo de la página
    /// (encabezados de YouTube, Gmail) se acomoda debajo y el scroll sigue pasando por detrás.
    @MainActor static func syncObscuredInset(_ webView: WKWebView) {
        observeDefaultsOnce()
        let inset = obscuredTop(for: webView)
        if webView.obscuredContentInsets.top != inset {
            webView.obscuredContentInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
        }
        // Con una franja tapada, WebKit pinta encima el color del encabezado fijo de la página
        // (Craft, Gmail) como bloque sólido: la barra se veía opaca. Lo apagamos para que pase
        // el contenido real por debajo. `defaults write com.gstudios.nook kurth.colorExtension -bool true`
        // lo regresa.
        let keepExtension = UserDefaults.standard.bool(forKey: "kurth.colorExtension")
        setPrivateBool(webView, "_setShouldSuppressTopColorExtensionView:", inset > 0 && !keepExtension)
        // Además WebKit dibuja su propia "scroll pocket" (el borde de Safari) sobre la franja: un
        // bloque de color que tapaba la página aunque la barra no tuviera fondo. La escondemos
        // con una razón propia (bit 7, que WebKit no usa) para que ninguna razón suya la regrese.
        let hidePocket = inset > 0 && !UserDefaults.standard.bool(forKey: "kurth.scrollPocket")
        setPrivateReason(webView, hidePocket ? "_addReasonToHideTopScrollPocket:" : "_removeReasonToHideTopScrollPocket:", 1 << 7)
    }

    @MainActor private static func setPrivateReason(_ object: NSObject, _ name: String, _ reason: UInt8) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let imp = object.method(for: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt8) -> Void
        unsafeBitCast(imp, to: Setter.self)(object, selector, reason)
    }

    /// Llama un setter BOOL interno de WebKit solo si existe: si una versión de macOS lo quita,
    /// Nook sigue igual y solo vuelve el comportamiento de fábrica.
    @MainActor private static func setPrivateBool(_ object: NSObject, _ name: String, _ value: Bool) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let imp = object.method(for: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(imp, to: Setter.self)(object, selector, value)
    }

    /// Los ajustes `kurth.*` se prueban en vivo: al cambiar uno, las páginas se reacomodan.
    /// Nook escribe defaults seguido; solo reacomodamos si cambió uno nuestro.
    @MainActor private static var observingDefaults = false
    @MainActor private static var lastKurthDefaults: [String] = []
    /// Ajustes que tocan a la página. (kurth.barMaterial lo observa SwiftUI por su cuenta.)
    private static let pageKeys = ["kurth.colorExtension", "kurth.scrollPocket"]
    @MainActor private static func kurthDefaults() -> [String] {
        pageKeys.map { "\($0)=\(UserDefaults.standard.object(forKey: $0).map { "\($0)" } ?? "-")" }
    }
    @MainActor private static func observeDefaultsOnce() {
        guard !observingDefaults else { return }
        observingDefaults = true
        lastKurthDefaults = kurthDefaults()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let now = kurthDefaults()
                guard now != lastKurthDefaults else { return }
                lastKurthDefaults = now
                NSApp.windows.compactMap(\.contentView).forEach(markWebViewsForLayout)
            }
        }
    }

    @MainActor private static func obscuredTop(for webView: WKWebView) -> CGFloat {
        guard floatingTopBar,
              let window = webView.window,
              let content = window.contentView,
              let bar = barRects[ObjectIdentifier(window)],
              webView.bounds.height > 0
        else { return 0 }
        // A coordenadas de SwiftUI: AppKit cuenta desde abajo, SwiftUI desde arriba.
        let inWindow = webView.convert(webView.bounds, to: nil)
        let top = content.bounds.height - inWindow.maxY
        let horizontal = inWindow.minX < bar.maxX && inWindow.maxX > bar.minX
        guard horizontal, top < bar.maxY else { return 0 }
        // WebKit lanza excepción con insets negativos o más altos que la vista.
        return min(max(0, bar.maxY - top), webView.bounds.height - 1)
    }

    @MainActor private static func markWebViewsForLayout(_ view: NSView) {
        if view is WKWebView { view.needsLayout = true; return }
        view.subviews.forEach(markWebViewsForLayout)
    }
}
