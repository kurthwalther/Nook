// Licensed under GPL-3.0. See LICENSE.
//
//  ExtensionLibraryOverlay.swift
//  Nook
//
//  Created by Bain Gurley on 21/09/2026.
//

import SwiftUI
import NookDesign
import NookWeb

/// Where the URL bar's overflow button sits, reported so the overlay can hang off it.
struct ExtensionLibraryAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The extension library and its overflow menu, drawn inside the window rather than in an
/// `NSPanel`. Only the key window renders the active Liquid Glass appearance, so a panel is
/// always foggy, and a key panel gets a heavier window shadow that squares off at its own edge.
/// In-window has neither problem and needs no event monitors to dismiss.
struct ExtensionLibraryOverlay: View {
    let anchor: Anchor<CGRect>?

    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @State private var isShowingMoreMenu = false
    /// kurth: cuándo se cerró por última vez. Al dar clic en el botón de extensiones con el panel
    /// abierto, esta capa recibe el clic y cierra, pero el botón de abajo también dispara al soltar
    /// (rareza de SwiftUI) y lo reabría en el mismo clic. El botón consulta esto y no reabre si el
    /// cierre fue hace un instante (Kurth, 25 sep).
    @MainActor static var cerradoEn: Date = .distantPast

    private let menuWidth: CGFloat = 300
    private let gap: CGFloat = 6
    /// kurth: el ancho del submenú (MoreMenuView), para decidir de qué lado cabe.
    private let moreMenuWidth: CGFloat = 260

    var body: some View {
        GeometryReader { proxy in
            if windowState.isExtensionLibraryVisible,
               let settings = browserManager.nookSettings,
               let anchor {
                let buttonFrame = proxy[anchor]
                let libraryX = originX(buttonFrame: buttonFrame, container: proxy.size)
                // kurth: el submenú se abre del lado donde cabe. Con el panel del agente abierto la
                // biblioteca queda pegada a la orilla derecha y el submenú se cortaba (Kurth, 25 sep).
                let menuOnLeft = isShowingMoreMenu && libraryX + menuWidth + gap + moreMenuWidth > proxy.size.width - gap

                ZStack(alignment: .topLeading) {
                    // kurth: cierra al soltar el mouse, sin exigir que no se haya movido (un clic
                    // real de mouse se mueve un pixel y el "toque" no se cumplía: nada pasaba). Y no
                    // cubre la barra: sus botones responden con el panel abierto, así extensiones
                    // lo cierra y chat abre el chat (Kurth, 25 sep).
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in close() })
                        .padding(.top, KurthChrome.floatingTopBar ? 44 : 0)

                    HStack(alignment: .top, spacing: gap) {
                        if menuOnLeft { moreMenu(anchor: .topTrailing) }

                        ExtensionLibraryView(
                            browserManager: browserManager,
                            windowState: windowState,
                            settings: settings,
                            onDismiss: { close() },
                            onShowMoreMenu: { isShowingMoreMenu.toggle() }
                        )
                        .frame(width: menuWidth)
                        .nookGlassEffect(in: NookDesign.Radius.shape(NookDesign.Radius.lg))

                        if isShowingMoreMenu && !menuOnLeft { moreMenu(anchor: .topLeading) }
                    }
                    .fixedSize()
                    // A la izquierda, el par se corre lo que mide el submenú: la biblioteca no se mueve.
                    .offset(x: menuOnLeft ? libraryX - (moreMenuWidth + gap) : libraryX,
                            y: buttonFrame.maxY + gap)
                }
                .animation(NookDesign.Motion.quick, value: isShowingMoreMenu)
                .onExitCommand { close() }
                .onChange(of: windowState.selectedItemID) { _, _ in close() }
            }
        }
        .ignoresSafeArea()
    }

    private func moreMenu(anchor: UnitPoint) -> some View {
        MoreMenuView(
            browserManager: browserManager,
            windowState: windowState,
            onDismiss: { isShowingMoreMenu = false }
        )
        .frame(width: moreMenuWidth)
        .nookGlassEffect(in: NookDesign.Radius.shape(NookDesign.Radius.lg))
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: anchor)))
    }

    /// Centred under the button, clamped so a narrow window cannot push it off screen. Centring
    /// uses the library's own width, not the pair's, so the library stays put when the overflow
    /// menu opens beside it.
    private func originX(buttonFrame: CGRect, container: CGSize) -> CGFloat {
        let preferred = buttonFrame.midX - menuWidth / 2
        let maxX = max(gap, container.width - menuWidth - gap)
        return min(max(gap, preferred), maxX)
    }

    private func close() {
        isShowingMoreMenu = false
        windowState.isExtensionLibraryVisible = false
        Self.cerradoEn = Date()
    }
}
