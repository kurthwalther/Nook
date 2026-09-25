// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarHoverOverlayView.swift
//  Nook
//
//  Created by Jonathan Caudill on 2025-09-13.
//

import SwiftUI
import AppKit
import NookDesign
import NookWeb
import NookUI

struct SidebarHoverOverlayView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @EnvironmentObject var hoverManager: HoverSidebarManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(\.nookSettings) var nookSettings

    private let cornerRadius: CGFloat = NookDesign.Radius.lg
    // kurth: 4 pt de las orillas con forma concéntrica a la ventana (KurthChrome.overlayShape).
    private let horizontalInset: CGFloat = KurthChrome.overlayInset
    private let verticalInset: CGFloat = KurthChrome.overlayInset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Only render overlay plumbing when the real sidebar is collapsed
        if !windowState.isSidebarVisible {
            ZStack(alignment: nookSettings.sidebarPosition == .left ? .leading : .trailing) {
                // Edge hover hotspot
                Color.clear
                    .frame(width: hoverManager.triggerWidth)
                    .contentShape(Rectangle())
                    .onHoverTracking { isIn in
                        if isIn && !windowState.isSidebarVisible {
                            // kurth: sin withAnimation; la animación vive en un solo lugar (abajo).
                            hoverManager.reveal()
                        }
                        NSCursor.arrow.set()
                    }

                if hoverManager.isOverlayVisible {
                    SpacesSideBarView()
                        .frame(width: windowState.sidebarWidth)
                        .environmentObject(browserManager)
                        .environment(windowState)
                        .environment(commandPalette)
                        .environmentObject(browserManager.gradientColorManager)
                        // kurth: la pestaña elegida con la misma pastilla de vidrio que en la barra fija
                        // (Kurth, 25 sep: "antes estaban como en un pill glass, mantén igual"). Upstream
                        // la cambiaba por un relleno blanco con borde para no poner vidrio sobre vidrio.
                        .environment(\.nookInsideGlass, false)
                        .frame(maxHeight: .infinity)
                        // kurth: el material de todas las barras, vidrio o el del panel fijo
                        // (Nook/Kurth/KurthPanelMaterial.swift), con la sombra flotante.
                        .modifier(KurthMaterialFlotante())
                        // kurth: la orilla se puede arrastrar para cambiar el ancho, como la fija.
                        // La flecha forzada deja libre esa franja; si no, peleaba con el cursor.
                        .alwaysArrowCursor(leavingFree: nookSettings.sidebarPosition == .left ? .maxXEdge : .minXEdge, width: 14)
                        .overlay(alignment: nookSettings.sidebarPosition == .left ? .trailing : .leading) {
                            SidebarResizeView(kurthEnFlotante: true)
                                .frame(maxHeight: .infinity)
                                .environmentObject(browserManager)
                                .environment(windowState)
                        }
                        .padding(nookSettings.sidebarPosition == .left ? .leading : .trailing, horizontalInset)
                        .padding(.vertical, verticalInset)
                        .transition(
                            .move(edge: nookSettings.sidebarPosition == .left ? .leading : .trailing)
                                .combined(with: .opacity)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: nookSettings.sidebarPosition == .left ? .topLeading : .topTrailing)
            // kurth: entra con resorte corto y sale más rápido con curva, como Zen.
            .animation(
                KurthMotion.respecting(reduceMotion, hoverManager.isOverlayVisible ? KurthMotion.reveal : KurthMotion.dismiss),
                value: hoverManager.isOverlayVisible
            )
            // Container remains passive; only overlay/hotspot intercept
        }
    }
}
