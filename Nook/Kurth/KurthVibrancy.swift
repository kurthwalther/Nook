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
//  sí difumine, con su capa de color a la fracción de `kurth.windowMaterialTint` (0–1).
//
//  Esa capa de color es la que hace que el vidrio de Apple se vea claro sobre cualquier fondo.
//  Quitarla del todo (lo que hacía la versión anterior, un booleano en false) deja el difuminado
//  crudo, y entonces la ventana toma la luminancia de lo que haya detrás: con una superficie
//  blanca al 0.30 sobre un fondo negro se medía #5E5E5E, casi modo oscuro. Medido el 23 sep en
//  la Pro, superficie blanca al 0.30 sobre negro / sobre blanco:
//    tinte 0 → #5E5E5E / #F8F8F8   0.5 → #A2A2A2 / #F1F1F1   1 → #DDDDDD / #ECECEC
//  El sidebar de Superconductor, la referencia de Kurth, mide #EFEFEF / #F4F4F4: es vidrio que
//  aclara, no transmisión. Por eso el default es 1 y la perilla baja hacia el difuminado crudo.
//
//  La ventana principal de Nook llega con isOpaque = true: así el servidor de ventanas no
//  compone lo de atrás y el efecto sale gris plano. Se marca no opaca al entrar.
//
//  Ajustes en vivo (UserDefaults, también por el MCP de desarrollo, ver KurthMCPTools):
//  kurth.windowMaterial (nombre del material, por defecto "sidebar") y kurth.windowMaterialTint
//  (0–1, por defecto 1). Un `false` guardado por la versión anterior se lee como 0 y conserva
//  su comportamiento.
//

import AppKit
import SwiftUI

struct KurthVibrancy: NSViewRepresentable {
    /// Cuánto del color del material se conserva (0–1). Lo calcula `tint(forOpacity:)` desde la
    /// opacidad del tema; `kurth.windowMaterialTint`, si está definido, lo anula.
    var tint: Double = 1
    /// .behindWindow para el fondo de la ventana (difumina lo que hay detrás de ella);
    /// .withinWindow para la barra lateral flotante, que va encima de la página: con
    /// .behindWindow se vería el escritorio atravesando la página.
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> BlurredView {
        let view = BlurredView()
        view.blendingMode = blending
        view.setTint(tint)
        return view
    }

    func updateNSView(_ view: BlurredView, context: Context) {
        if view.blendingMode != blending { view.blendingMode = blending }
        view.setTint(tint)
    }

    /// Cuánto vidrio queda debajo de la superficie, según la opacidad del tema. Una sola perilla
    /// que va de sólida (1) a vidrio claro a dejar ver lo de atrás (el mínimo), que es lo que
    /// hace Superconductor: al abrirla no solo baja el alfa, también abre su vidrio.
    /// Lineal entre `minTint` en `KurthTheme.minOpacity` y 1 en opacidad 1. Medido con superficie
    /// blanca al 0.24 sobre negro: tinte 0 → #4D4D4D (el sidebar deja de leerse), 0.3 → #7D7D7D,
    /// 0.45 → #939393, 1 → #DBDBDB. De ahí sale `minTint`.
    static let minTint = 0.45

    static func tint(forOpacity opacity: Double) -> Double {
        let span = KurthTheme.maxOpacity - KurthTheme.minOpacity
        let t = span > 0 ? (opacity - KurthTheme.minOpacity) / span : 1
        return minTint + (1 - minTint) * min(1, max(0, t))
    }

    static let materials: [String: NSVisualEffectView.Material] = [
        "sidebar": .sidebar, "underWindowBackground": .underWindowBackground,
        "windowBackground": .windowBackground, "contentBackground": .contentBackground,
        "hudWindow": .hudWindow, "fullScreenUI": .fullScreenUI, "menu": .menu, "popover": .popover,
        "headerView": .headerView, "titlebar": .titlebar, "sheet": .sheet,
        "underPageBackground": .underPageBackground, "toolTip": .toolTip, "selection": .selection,
    ]

    final class BlurredView: NSVisualEffectView {
        /// El que pide el tema.
        private var requestedTint = 1.0
        /// El que está aplicado (el override de UserDefaults si existe, si no el del tema).
        private var tintAmount = 1.0
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

        func setTint(_ tint: Double) {
            guard tint != requestedTint else { return }
            requestedTint = tint
            applyPrefs()
        }

        private func applyPrefs() {
            let defaults = UserDefaults.standard
            let chosen = KurthVibrancy.materials[defaults.string(forKey: "kurth.windowMaterial") ?? ""] ?? .sidebar
            // Un booleano de la versión anterior llega como NSNumber 0/1: mismo significado.
            let override = (defaults.object(forKey: "kurth.windowMaterialTint") as? NSNumber)?.doubleValue
            let tint = override ?? requestedTint
            guard chosen != material || tint != tintAmount else { return }
            material = chosen
            tintAmount = min(1, max(0, tint))
            needsDisplay = true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
        }

        override func updateLayer() {
            super.updateLayer()
            // super vuelve a poner el color del material en cada pasada; se escala después.
            if tintAmount < 1, let layer { Self.scaleTint(layer, tintAmount) }
        }

        /// Baja el alfa de la capa de color del material sin tocar el difuminado, que no vive
        /// en el árbol de capas (lo pone el servidor de ventanas según el material).
        private static func scaleTint(_ layer: CALayer, _ amount: Double) {
            if let color = layer.backgroundColor {
                layer.backgroundColor = amount <= 0 ? nil : color.copy(alpha: color.alpha * amount)
            }
            layer.sublayers?.forEach { scaleTint($0, amount) }
        }
    }
}
