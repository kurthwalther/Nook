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

    /// Barra lateral que aparece al pasar el mouse: 4 pt de las orillas, como Zen (8 dejaba un
    /// hueco en la esquina: radio 12 dentro de una ventana de radio 16 no es concéntrico, y en
    /// la diagonal la separación era de 9.6 pt contra 8 en los lados).
    static let overlayInset: CGFloat = 4
    /// El radio sale de la esquina real de la ventana menos la separación (16 − 4 = 12).
    static var overlayShape: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true)
    }

    /// Tarjeta de la página con radios concéntricos (la regla de Apple): cada esquina = esquina
    /// de la ventana − separación, calculado contra la ventana real y no con un número fijo
    /// (medido el 23 sep: ventana ~17 pt, página a 8 pt, pedía ~9 y tenía 8). Donde la esquina
    /// no toca una de la ventana (junto a la barra lateral fija) queda en 8.
    static var pageShape: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(pageMinimumRadius)))
    }

    /// La barra superior cubre la parte de arriba de la tarjeta: mismas esquinas arriba, rectas abajo.
    static var pageTopShape: ConcentricRectangle {
        ConcentricRectangle(uniformTopCorners: .concentric(minimum: .fixed(pageMinimumRadius)), uniformBottomCorners: .fixed(0))
    }

    /// Radio mínimo de la página. Concéntrico da 8 (16 − 8); `kurth.pageRadius` lo sube para
    /// probar (Kurth pidió ver 9 el 23 sep). Se aplica al reiniciar Nook.
    static var pageMinimumRadius: CGFloat {
        let override = UserDefaults.standard.double(forKey: "kurth.pageRadius")
        return override > 0 ? override : 8
    }

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
        if let page = webView as? FocusableWKWebView { KurthPageState.attach(to: page) }
        let inset = obscuredTop(for: webView)
        if webView.obscuredContentInsets.top != inset {
            webView.obscuredContentInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
        }
        // Si la página tiene encabezado fijo pegado arriba (YouTube), WebKit rellena la franja
        // tapada con su color para que el contenido no se asome por encima del encabezado. Se
        // queda encendido: lo que tapaba Craft era la scroll pocket (abajo), no esto.
        // `defaults write com.gstudios.nook kurth.colorExtension -bool false` lo apaga.
        let keepExtension = UserDefaults.standard.object(forKey: "kurth.colorExtension") as? Bool ?? true
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
