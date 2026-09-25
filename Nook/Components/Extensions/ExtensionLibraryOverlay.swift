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
    /// kurth: el cierre lo decide un monitor de mouseDown, no una capa de SwiftUI: un clic real de
    /// trackpad se mueve un pixel y ni el "toque" de la capa ni el botón de abajo lo tomaban (nada
    /// pasaba). En el mouseDown: dentro del panel, sigue; sobre el botón de extensiones, cierra y
    /// se traga el clic (para que el botón no reabra); en cualquier otro lado, cierra y el clic
    /// sigue (chat abre el chat, la página recibe el clic). Kurth, 25 sep.
    @State private var marcos = Marcos()
    @State private var monitor: Any?

    @MainActor final class Marcos {
        var boton = CGRect.zero
        var panel = CGRect.zero
    }

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
                let _ = { marcos.boton = buttonFrame }()
                let libraryX = originX(buttonFrame: buttonFrame, container: proxy.size)
                // kurth: el submenú se abre del lado donde cabe. Con el panel del agente abierto la
                // biblioteca queda pegada a la orilla derecha y el submenú se cortaba (Kurth, 25 sep).
                let menuOnLeft = isShowingMoreMenu && libraryX + menuWidth + gap + moreMenuWidth > proxy.size.width - gap

                ZStack(alignment: .topLeading) {
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
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("extlib")) } action: { marcos.panel = $0 }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .coordinateSpace(name: "extlib")
                .animation(NookDesign.Motion.quick, value: isShowingMoreMenu)
                .onExitCommand { close() }
                .onChange(of: windowState.selectedItemID) { _, _ in close() }
            }
        }
        .ignoresSafeArea()
        .onChange(of: windowState.isExtensionLibraryVisible, initial: true) { _, abierto in
            if abierto { instalarMonitor() } else { quitarMonitor() }
        }
        .onDisappear { quitarMonitor() }
    }

    private func instalarMonitor() {
        guard monitor == nil else { return }
        let marcos = self.marcos
        let estado = windowState
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { evento in
            MainActor.assumeIsolated {
                guard let ventana = evento.window, ventana === (estado.windowHandle as? NSWindow),
                      let contenido = ventana.contentView else { return evento }
                let enVentana = evento.locationInWindow
                let p = CGPoint(x: enVentana.x, y: contenido.bounds.height - enVentana.y)
                if marcos.panel.contains(p) { return evento }
                close()
                return marcos.boton.contains(p) ? nil : evento
            }
        }
    }

    private func quitarMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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
