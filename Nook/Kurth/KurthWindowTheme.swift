// Licensed under GPL-3.0. See LICENSE.
//
//  KurthWindowTheme.swift
//  Nook (rama kurth)
//
//  El fondo de la ventana con el tema de SU Space. Upstream leía el acento de
//  GradientColorManager, que es uno para toda la app: una ventana inactiva mostrando otro Space
//  pintaba el color del Space de la ventana activa. Aquí cada ventana lee el suyo.
//  Al cambiar de Space el tema cruza en 0.25 s sin rebote, como Zen (las dos capas ::before y
//  ::after de zen-browser-ui.css); un solo Color no podía cruzar de 2 a 3 colores.
//
//  Debajo del tinte va lo de atrás de la ventana, difuminado (KurthVibrancy). La opacidad del
//  tema decide dos cosas a la vez, y por eso es una sola perilla: cuánta superficie se pone
//  encima y cuánto vidrio queda debajo (KurthVibrancy.tint(forOpacity:)). Upstream quitó su blur en
//  60d0d34 porque cuesta más que un fondo plano (el servidor de ventanas difumina lo de atrás en
//  cada cuadro que cambia); volvió por decisión de Kurth, 23 sep.
//

import SwiftUI
import NookDesign
import NookWeb

struct KurthWindowTheme: View {
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(TabsController.self) private var tabs
    @Environment(WindowRegistry.self) private var windowRegistry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let spaceID = windowState.isIncognito ? nil : windowState.spaceID
        let theme = Self.theme(window: windowState, tabs: tabs)
        let isActive = windowRegistry.activeWindowId == windowState.id

        ZStack {
            KurthVibrancy(tint: KurthVibrancy.tint(forOpacity: theme.opacity))
            KurthThemeBackground(theme: theme, isActive: isActive)
                .id(spaceID)
                .transition(.opacity)
            KurthVidrioDeVentana() // con kurth.panelMaterial = glass (KurthPanelMaterial.swift)
        }
        .animation(KurthMotion.respecting(reduceMotion, .smooth(duration: 0.25)), value: spaceID)
        .animation(NookDesign.Motion.standard, value: isActive)
    }

    /// El tema que pinta esta ventana (el borrador si se está editando).
    @MainActor
    static func theme(window: BrowserWindowState, tabs: TabsController) -> KurthTheme {
        let spaceID = window.isIncognito ? nil : window.spaceID
        let accent = window.isIncognito
            ? SpaceGradient.incognito.primaryColorHex
            : spaceID.flatMap { tabs.space($0)?.accentHex }
        return KurthThemeStore.shared.theme(for: spaceID, accentHex: accent)
    }
}

/// El tema dentro de la barra lateral que sale al pasar el mouse: la misma porción del degradado
/// que se vería con la barra fija, porque se dibuja al tamaño de la ventana y se recorre a su
/// posición. Debajo, el mismo material que el fondo fijo pero difuminando la página que tiene
/// abajo (.withinWindow), así que la opacidad del tema deja ver la página, no el escritorio.
struct KurthHoverTheme: View {
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(TabsController.self) private var tabs
    /// Solo el tema, sin el material de abajo: para ponerlo sobre Liquid Glass (la tarjeta del
    /// agente, KurthAgentHoverOverlay), donde el difuminado ya lo hace el vidrio.
    var soloTema = false

    var body: some View {
        let theme = KurthWindowTheme.theme(window: windowState, tabs: tabs)
        ZStack {
            // El mismo material y el mismo vidrio que el fondo fijo (KurthWindowTheme), pero
            // difuminando la página de abajo. Antes era Liquid Glass y no casaba con el fijo
            // (Kurth, 24 sep: "que sea como el fijo").
            if !soloTema {
                KurthVibrancy(tint: KurthVibrancy.tint(forOpacity: theme.opacity), blending: .withinWindow)
            }
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                let window = windowState.window?.contentView?.bounds.size ?? frame.size
                KurthThemeBackground(theme: theme)
                    .frame(width: window.width, height: window.height)
                    .offset(x: -frame.minX, y: -frame.minY)
            }
        }
        .allowsHitTesting(false)
    }
}
