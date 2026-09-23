// Licensed under GPL-3.0. See LICENSE.
//
//  KurthVibrancy.swift
//  Nook (rama kurth)
//
//  Difuminado puro de lo que hay detrás de la ventana, sin el color del material. Es la receta
//  de `BlurredView` en gpui de Zed (crates/gpui/src/platform/mac/window.rs, Apache-2.0),
//  reescrita en Swift: un NSVisualEffectView .behindWindow al que se le quita el fondo de cada
//  capa, la capa que tiñe con el fondo de pantalla (CAChameleonLayer) y el filtro que sube la
//  saturación ("colorSaturate"). El color lo pone el tema encima, así que su opacidad es la
//  transparencia real. Con .sidebar el material traía su propio blanco y un rojo puro detrás
//  apenas movía el color un 6 % (medido el 23 sep).
//
//  La ventana principal de Nook llega con isOpaque = true: así el servidor de ventanas no
//  compone lo de atrás y el efecto sale gris plano. Se marca no opaca al entrar.
//

import AppKit
import SwiftUI

struct KurthVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> BlurredView { BlurredView() }
    func updateNSView(_ view: BlurredView, context: Context) {}

    final class BlurredView: NSVisualEffectView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            // Material semántico sin color propio (el que usa gpui); activo aunque la ventana no
            // lo esté, como Arc y Zen: el tema no se apaga a gris al cambiar de app.
            material = .selection
            blendingMode = .behindWindow
            state = .active
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
        }

        override func updateLayer() {
            super.updateLayer()
            if let layer { Self.stripTint(layer) }
        }

        private static func stripTint(_ layer: CALayer) {
            layer.backgroundColor = nil
            if String(describing: type(of: layer)) == "CAChameleonLayer" {
                layer.isHidden = true
                return
            }
            // CAFilter es privado: se reconoce por su descripción ("colorSaturate"; si algún día
            // fuera CIFilter, diría "inputSaturation"). Por eso se busca "Saturat".
            if let filters = layer.filters,
               let i = filters.firstIndex(where: { String(describing: $0).contains("Saturat") }) {
                var kept = filters
                kept.remove(at: i)
                layer.filters = kept
            }
            layer.sublayers?.forEach(stripTint)
        }
    }
}
