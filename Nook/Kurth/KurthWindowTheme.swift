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

import SwiftUI
import NookDesign
import NookWeb

struct KurthWindowTheme: View {
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(TabsController.self) private var tabs
    @Environment(WindowRegistry.self) private var windowRegistry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let store = KurthThemeStore.shared
        let spaceID = windowState.isIncognito ? nil : windowState.spaceID
        let accent = windowState.isIncognito
            ? SpaceGradient.incognito.primaryColorHex
            : spaceID.flatMap { tabs.space($0)?.accentHex }
        let theme = store.theme(for: spaceID, accentHex: accent)
        let isActive = windowRegistry.activeWindowId == windowState.id

        ZStack {
            NookDesign.Surface.windowBackground
            KurthThemeBackground(theme: theme, isActive: isActive)
                .id(spaceID)
                .transition(.opacity)
        }
        .animation(KurthMotion.respecting(reduceMotion, .smooth(duration: 0.25)), value: spaceID)
        .animation(NookDesign.Motion.standard, value: isActive)
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
