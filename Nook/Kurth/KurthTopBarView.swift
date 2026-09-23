// Licensed under GPL-3.0. See LICENSE.
//
//  KurthTopBarView.swift
//  Nook (rama kurth)
//
//  Barra superior de Kurth: Arc en la forma (botones sencillos, dominio al centro, extensiones
//  y chat a la derecha) y iOS en el material (blur sobre la página, sin línea divisoria, gris
//  claro u oscuro según la página). Reemplaza a TopBarView cuando KurthChrome.floatingTopBar.
//

import AppKit
import SwiftUI
import WebKit
import NookDesign
import NookWeb
import NookUI

struct KurthTopBarView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @EnvironmentObject var hoverSidebarManager: HoverSidebarManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(\.nookSettings) var nookSettings

    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0
    @State private var didCopy = false
    @State private var isHoveringAddress = false

    var body: some View {
        let sideWidth = max(leadingWidth, trailingWidth)

        HStack(spacing: 0) {
            leadingControls
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
                .frame(width: sideWidth, alignment: .leading)

            address
                .frame(maxWidth: .infinity)

            trailingControls
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
                .frame(width: sideWidth, alignment: .trailing)
        }
        .padding(.horizontal, NookDesign.Spacing.sm)
        .frame(height: KurthChrome.topBarHeight)
        .frame(maxWidth: .infinity)
        .background {
            barMaterial
                .backgroundDraggable()
        }
        .background(
            KurthBarProbe(showsWindowButtons: showsWindowButtons)
        )
        .environment(\.colorScheme, pageScheme ?? systemScheme)
        .animation(NookDesign.Motion.standard, value: pageScheme)
    }

    // MARK: - Fondo

    /// Material de barra de iOS: desenfoca lo que pasa por debajo y se apaga hacia abajo,
    /// sin línea que corte contra la página.
    private var barMaterial: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: NookDesign.Radius.md, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: NookDesign.Radius.md,
            style: .continuous
        )
            .fill(.bar)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.bar)
                    .frame(height: KurthChrome.topBarFade)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                    .offset(y: KurthChrome.topBarFade)
                    .allowsHitTesting(false)
            }
    }

    // MARK: - Izquierda: barra lateral, atrás, adelante, recargar

    private var leadingControls: some View {
        HStack(spacing: NookDesign.Spacing.xxs) {
            Button("Toggle Sidebar", systemImage: nookSettings.sidebarPosition == .left ? "sidebar.left" : "sidebar.right") {
                browserManager.toggleSidebar(for: windowState)
            }
            .kurthBarIcon()

            Button("Go Back", systemImage: "chevron.backward") {
                if let webView = windowWebView { webView.goBack() } else { session?.goBack() }
            }
            .kurthBarIcon()
            .disabled(!(session?.canGoBack ?? false))
            .contextMenu {
                NavigationHistoryContextMenu(historyType: .back, windowState: windowState)
            }

            Button("Go Forward", systemImage: "chevron.forward") {
                if let webView = windowWebView { webView.goForward() } else { session?.goForward() }
            }
            .kurthBarIcon()
            .disabled(!(session?.canGoForward ?? false))
            .contextMenu {
                NavigationHistoryContextMenu(historyType: .forward, windowState: windowState)
            }

            Button {
                if session?.isLoading == true { session?.stop() } else { session?.refresh() }
            } label: {
                Image(systemName: session?.isLoading == true ? "xmark" : "arrow.clockwise")
                    .contentTransition(.symbolEffect(.replace))
            }
            .kurthBarIcon()
        }
    }

    // MARK: - Centro: dominio y copiar

    @ViewBuilder
    private var address: some View {
        if let tab = browserManager.tabs.selectedSession(in: windowState) {
            HStack(spacing: NookDesign.Spacing.sm) {
                Button {
                    copyURL(tab.url)
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "link")
                        .contentTransition(.symbolEffect(.replace))
                        .font(NookDesign.Font.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Copiar URL")

                Text(Self.shortHost(tab.url))
                    .font(NookDesign.Font.body)
                    .foregroundStyle(isHoveringAddress ? .primary : .secondary)
                    .truncationMode(.head)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { commandPalette.openWithCurrentURL(tab.url) }
                    .onHoverTracking { isHoveringAddress = $0 }
            }
            .padding(.horizontal, NookDesign.Spacing.md)
        }
    }

    /// Solo el dominio, sin "www.": la ruta y el título salen de la barra.
    static func shortHost(_ url: URL) -> String {
        guard let host = url.host(), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func copyURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        withAnimation(NookDesign.Motion.quick) { didCopy = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(NookDesign.Motion.quick) { didCopy = false }
        }
    }

    // MARK: - Derecha: extensiones fijadas, biblioteca de extensiones, chat

    private var trailingControls: some View {
        HStack(spacing: NookDesign.Spacing.xxs) {
            if let extensionManager = browserManager.extensionManager {
                let pinnedIDs = nookSettings.pinnedExtensionIDs
                let pinned = extensionManager.installedExtensions.filter { pinnedIDs.contains($0.id) }
                if !pinned.isEmpty {
                    ExtensionActionView(extensions: pinned)
                        .environmentObject(browserManager)
                }

                Button("Extensions", systemImage: "slider.horizontal.2.square") {
                    windowState.isExtensionLibraryVisible.toggle()
                }
                .kurthBarIcon()
                // El panel de extensiones de WindowView se cuelga de este marco.
                .anchorPreference(key: ExtensionLibraryAnchorKey.self, value: .bounds) { $0 }
            }

            if nookSettings.showAIAssistant {
                Button("Chat", systemImage: windowState.isSidebarAIChatVisible ? "bubble.left.fill" : "bubble.left") {
                    browserManager.toggleAISidebar(for: windowState)
                }
                .kurthBarIcon()
            }
        }
    }

    // MARK: - Estado

    /// Nil mientras otra ventana tiene la página: los controles quedan inertes.
    private var session: PageSession? {
        browserManager.tabs.controllableSession(in: windowState)
    }

    private var windowWebView: WKWebView? {
        session.flatMap { browserManager.webViewCoordinator?.getWebView(for: $0.itemID, in: windowState.id) }
    }

    /// Gris claro u oscuro según el color que Nook ya muestrea de la parte alta de la página.
    private var pageScheme: ColorScheme? {
        guard let tab = browserManager.tabs.selectedSession(in: windowState),
              let color = tab.topBarBackgroundColor ?? tab.pageBackgroundColor
        else { return nil }
        return color.isPerceivedDark ? .dark : .light
    }

    @Environment(\.colorScheme) private var systemScheme

    /// Semáforos solo con barra lateral a la vista: la fija o la que sale al pasar por el borde.
    private var showsWindowButtons: Bool {
        windowState.isSidebarVisible || hoverSidebarManager.isOverlayVisible
    }
}

private extension View {
    func kurthBarIcon() -> some View {
        self
            .labelStyle(.iconOnly)
            .buttonStyle(NookIconButtonStyle())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Sonda de la barra

/// Vive detrás de la barra: le pasa a KurthChrome dónde está la barra (para el inset de las
/// páginas) y esconde o muestra los semáforos.
private struct KurthBarProbe: NSViewRepresentable {
    let showsWindowButtons: Bool

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.showsWindowButtons = showsWindowButtons
        view.sync()
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.detach()
    }

    final class ProbeView: NSView {
        var showsWindowButtons = true
        /// La ventana sigue aquí cuando SwiftUI desmonta la vista y `window` ya es nil.
        private weak var hostWindow: NSWindow?
        private let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { hostWindow = window }
            sync()
        }

        override func layout() {
            super.layout()
            sync()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            sync()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func sync() {
            guard let window, let content = window.contentView else { return }
            let inWindow = convert(bounds, to: nil)
            let rect = CGRect(x: inWindow.minX, y: content.bounds.height - inWindow.maxY,
                              width: inWindow.width, height: inWindow.height)
            KurthChrome.setBarRect(rect, in: window)
            setWindowButtons(hidden: !showsWindowButtons, in: window)
        }

        func detach() {
            guard let window = window ?? hostWindow else { return }
            KurthChrome.setBarRect(nil, in: window)
            setWindowButtons(hidden: false, in: window)
        }

        private func setWindowButtons(hidden: Bool, in window: NSWindow) {
            // En pantalla completa manda FullScreenToolbarView.
            guard !window.styleMask.contains(.fullScreen) else { return }
            for type in buttonTypes {
                window.standardWindowButton(type)?.isHidden = hidden
            }
        }
    }
}
