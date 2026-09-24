// Licensed under GPL-3.0. See LICENSE.
//
//  KurthVibrancy.swift
//  Nook (rama kurth)
//
//  Difuminado de lo que hay detrás de la ventana, bajo la superficie del tema
//  (KurthThemeBackground), cuya opacidad decide cuánto se ve.
//
//  En macOS 27 el difuminado de un NSVisualEffectView .behindWindow no vive en su árbol de
//  capas: lo pone el servidor de ventanas según el material, y la vista solo lleva una capa con
//  el color del material (volcado del 23 sep: NSViewBackingLayer > CALayer con fondo, sin
//  filtros). Por eso la receta de gpui (`BlurredView`: material .selection y quitar colores) aquí
//  dejaba transparencia literal: .selection no pide difuminado. Lo que sirve es un material que
//  sí difumine y quitarle solo esa capa de color (kurth.windowMaterialTint = false).
//
//  La ventana principal de Nook llega con isOpaque = true: así el servidor de ventanas no
//  compone lo de atrás y el efecto sale gris plano. Se marca no opaca al entrar.
//
//  Ajustes en vivo (UserDefaults, también por el MCP de desarrollo, ver KurthMCPTools):
//  kurth.windowMaterial (nombre del material, por defecto "sidebar") y kurth.windowMaterialTint.
//

import AppKit
import SwiftUI

struct KurthVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> BlurredView { BlurredView() }
    func updateNSView(_ view: BlurredView, context: Context) {}

    static let materials: [String: NSVisualEffectView.Material] = [
        "sidebar": .sidebar, "underWindowBackground": .underWindowBackground,
        "windowBackground": .windowBackground, "contentBackground": .contentBackground,
        "hudWindow": .hudWindow, "fullScreenUI": .fullScreenUI, "menu": .menu, "popover": .popover,
        "headerView": .headerView, "titlebar": .titlebar, "sheet": .sheet,
        "underPageBackground": .underPageBackground, "toolTip": .toolTip, "selection": .selection,
    ]

    final class BlurredView: NSVisualEffectView {
        private var keepsTint = false
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            blendingMode = .behindWindow
            // Activo aunque la ventana no lo esté, como Arc y Zen.
            state = .active
            applyPrefs()
            observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyPrefs() }
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        private func applyPrefs() {
            let defaults = UserDefaults.standard
            let chosen = KurthVibrancy.materials[defaults.string(forKey: "kurth.windowMaterial") ?? ""] ?? .sidebar
            let tint = defaults.bool(forKey: "kurth.windowMaterialTint")
            guard chosen != material || tint != keepsTint else { return }
            material = chosen
            keepsTint = tint
            needsDisplay = true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
        }

        override func updateLayer() {
            super.updateLayer()
            // super vuelve a poner el color del material en cada pasada; se quita después.
            if !keepsTint, let layer { Self.stripTint(layer) }
        }

        private static func stripTint(_ layer: CALayer) {
            layer.backgroundColor = nil
            layer.sublayers?.forEach(stripTint)
        }
    }
}
