// Licensed under GPL-3.0. See LICENSE.
//
//  ZoomManager.swift
//  Nook
//
//  Created by Assistant on 13/10/2025.
//

import Foundation
import WebKit

@Observable
@MainActor
class ZoomManager {
    // kurth: sin presets; de 10 en 10 % entre 50 y 300 % (KurthZoom).

    private var tabZoomLevels: [UUID: Double] = [:]

    var currentZoomLevel: Double = 1.0

    // kurth: redondeado; con Int() 1.1 × 100 se leía 110 pero 0.7 × 100 se leía 69.
    var currentZoomPercentage: Int { Int((currentZoomLevel * 100).rounded()) }

    var isAtMinimumZoom: Bool { currentZoomLevel <= KurthZoom.minimo + 0.001 }

    var isAtMaximumZoom: Bool { currentZoomLevel >= KurthZoom.maximo - 0.001 }

    /// kurth: el interruptor del popup (KurthZoom): un nivel para todo el navegador o uno por pestaña.
    var kurthTodoElNavegador = KurthZoom.todoElNavegador
    /// kurth: para llevar el nivel de todo el navegador a cada página abierta.
    @ObservationIgnored weak var kurthCoordinador: WebViewCoordinator?

    func getZoomPercentageDisplay() -> String {
        return "\(currentZoomPercentage)%"
    }

    // MARK: - Public Methods

    /// Apply a zoom level to a web view.
    func applyZoom(_ zoomLevel: Double, to webView: WKWebView, tabId: UUID) {
        let clampedZoom = KurthZoom.limitar(zoomLevel) // kurth

        poner(clampedZoom, en: webView)

        currentZoomLevel = clampedZoom
        // kurth: en "todo el navegador" el nivel es uno: se guarda y va a todas las páginas abiertas.
        // Los de cada pestaña no se tocan, para que vuelvan si se regresa a "esta pestaña".
        if kurthTodoElNavegador {
            KurthZoom.nivelDelNavegador = clampedZoom
            for vista in kurthCoordinador?.kurthVistas.map(\.vista) ?? [] where vista !== webView {
                poner(clampedZoom, en: vista)
            }
        } else {
            tabZoomLevels[tabId] = clampedZoom
        }
    }

    // pageZoom relays the page out, so text and canvases re-render sharp. magnification is a
    // layer scale a stray trackpad pinch leaves behind, and it resamples canvas-drawn pages.
    private func poner(_ nivel: Double, en webView: WKWebView) {
        webView.pageZoom = nivel
        webView.magnification = 1.0
    }

    func zoomIn(for webView: WKWebView, tabId: UUID) {
        applyZoom(nextZoomLevel(from: kurthNivel(for: tabId), direction: .up), to: webView, tabId: tabId)
    }

    func zoomOut(for webView: WKWebView, tabId: UUID) {
        applyZoom(nextZoomLevel(from: kurthNivel(for: tabId), direction: .down), to: webView, tabId: tabId)
    }

    /// kurth: al navegar, la página toma el nivel que le toca (el de todo el navegador o el de su
    /// pestaña) en vez de volver a 100 %. No mueve lo que dice el popup: eso es de la pestaña a la vista.
    func kurthAlNavegar(_ webView: WKWebView, tabId: UUID) {
        poner(kurthNivel(for: tabId), en: webView)
    }

    /// kurth: el interruptor. Lo que se está viendo se queda: pasa a ser el nivel de todo el
    /// navegador, o el de la pestaña activa; las demás pestañas vuelven al suyo (100 % si no tenían).
    func kurthCambiarModo(todoElNavegador: Bool, pestañaActiva: UUID?) {
        guard todoElNavegador != kurthTodoElNavegador else { return }
        let visto = currentZoomLevel
        kurthTodoElNavegador = todoElNavegador
        KurthZoom.todoElNavegador = todoElNavegador
        if todoElNavegador {
            KurthZoom.nivelDelNavegador = visto
        } else if let pestañaActiva {
            tabZoomLevels[pestañaActiva] = visto
        }
        for (pestaña, vista) in kurthCoordinador?.kurthVistas ?? [] {
            poner(todoElNavegador ? visto : zoomLevel(for: pestaña), en: vista)
        }
        currentZoomLevel = visto
    }

    /// kurth: el nivel que corresponde a esa pestaña según el modo.
    private func kurthNivel(for tabId: UUID) -> Double {
        kurthTodoElNavegador ? KurthZoom.nivelDelNavegador : zoomLevel(for: tabId)
    }

    /// Back to 100%. Also runs on navigation, so a page never inherits the last one's zoom.
    func resetZoom(for webView: WKWebView, tabId: UUID) {
        applyZoom(1.0, to: webView, tabId: tabId)
    }

    /// Points the displayed level at `tabId`. Zoom is per tab, the readout is one value.
    func showZoomLevel(for tabId: UUID?) {
        currentZoomLevel = kurthTodoElNavegador ? KurthZoom.nivelDelNavegador : tabId.map { zoomLevel(for: $0) } ?? 1.0 // kurth
    }

    /// Remove the zoom level for a closed tab
    func removeTabZoomLevel(for tabId: UUID) {
        tabZoomLevels.removeValue(forKey: tabId)
    }

    // MARK: - Private

    private func zoomLevel(for tabId: UUID) -> Double {
        return tabZoomLevels[tabId] ?? 1.0
    }

    /// kurth: el siguiente múltiplo de 10 % en esa dirección (KurthZoom.siguiente).
    private func nextZoomLevel(from currentLevel: Double, direction: ZoomDirection) -> Double {
        KurthZoom.siguiente(desde: currentLevel, subiendo: direction == .up)
    }
}

// MARK: - Supporting Types

private enum ZoomDirection {
    case up
    case down
}
