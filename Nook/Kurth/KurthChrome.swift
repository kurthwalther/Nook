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
        let inset = obscuredTop(for: webView)
        if webView.obscuredContentInsets.top != inset {
            webView.obscuredContentInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
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
