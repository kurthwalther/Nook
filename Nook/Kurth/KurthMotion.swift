// Licensed under GPL-3.0. See LICENSE.
//
//  KurthMotion.swift
//  Nook (rama kurth)
//
//  Movimiento de la capa Kurth, tomado de Zen. Zen anima con la librería Motion y describe sus
//  resortes como {duration d, bounce b}; en SwiftUI es Spring(settlingDuration: d,
//  dampingRatio: 1 − b), que resuelve la misma ecuación (misma rigidez y fricción; verificado
//  contra el SDK 27 el 23 sep 2026). La regla que se siente "consciente": entradas con resorte
//  corto, salidas más rápidas con curva, y nada de easeInOut simétrico.
//

import AppKit
import SwiftUI

enum KurthMotion {
    /// Cambios de estructura (cambio de Space, reacomodos): 0.25 s sin rebote.
    static let structural = Animation.spring(Spring(settlingDuration: 0.25, dampingRatio: 1))
    /// Entradas (barra lateral por hover, paleta): 0.21 s con un rebote apenas perceptible (1 %).
    static let reveal = Animation.spring(duration: 0.21, bounce: 0.18)
    /// Salidas: el `ease` de CSS en 0.15 s. Siempre más cortas que la entrada.
    static let dismiss = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.15)
    /// Llegadas con peso (apertura de ventana): 0.5 s, 1.5 % de rebote.
    static let arrive = Animation.spring(Spring(settlingDuration: 0.5, dampingRatio: 0.8))
    /// Filas que aparecen y se van (pestañas).
    static let rowIn = Animation.easeOut(duration: 0.12)
    static let rowOut = Animation.easeOut(duration: 0.10)

    static let stagger: TimeInterval = 0.03
    static let secondaryDelay: TimeInterval = 0.15
    /// Lo que espera la barra lateral antes de irse cuando el mouse sale.
    static let hoverGrace: TimeInterval = 0.15
    static let pressScale: CGFloat = 0.985

    /// Con "Reducir movimiento" de macOS, todo movimiento pasa a un fundido corto.
    static let reduced = Animation.easeOut(duration: 0.12)

    static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation {
        reduceMotion ? reduced : animation
    }

    /// Para código que no está en una vista (managers de AppKit).
    @MainActor static var systemReducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
