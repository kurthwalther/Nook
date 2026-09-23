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
//  Debajo del tinte va lo de atrás de la ventana, difuminado y sin color propio (KurthVibrancy,
//  la receta de gpui): la opacidad del tema decide cuánto se ve. Upstream quitó su blur en
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
            KurthVibrancy()
            KurthThemeBackground(theme: theme, isActive: isActive)
                .id(spaceID)
                .transition(.opacity)
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
/// posición. Va sobre el vidrio, así que la opacidad del tema también deja ver lo de atrás.
struct KurthHoverTheme: View {
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(TabsController.self) private var tabs

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let window = windowState.window?.contentView?.bounds.size ?? frame.size
            KurthThemeBackground(theme: KurthWindowTheme.theme(window: windowState, tabs: tabs))
                .frame(width: window.width, height: window.height)
                .offset(x: -frame.minX, y: -frame.minY)
        }
        .allowsHitTesting(false)
    }
}

/// Página vacía (sin pestaña) transparente: el tema se ve continuo en vez de reiniciar un
/// segundo degradado dentro de la tarjeta, que además iba a radio 12 contra 8 de la página.
struct KurthEmptyPage: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.stars")
                .font(NookDesign.Font.display)
                .blendMode(.overlay)
            Text("Ah, peace.")
                .font(NookDesign.Font.title)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
