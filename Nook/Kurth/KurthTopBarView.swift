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
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var systemScheme

    /// Variante de barra, se cambia con clic derecho en la barra:
    /// "capsules" = tipo Safari, tres cápsulas de Liquid Glass sobre la página;
    /// "tinted"   = blur con una capa del color del sitio encima.
    @AppStorage("kurth.barStyle") private var barStyle = "capsules"
    /// Ajustes en vivo (`defaults write com.gstudios.nook <clave> -float <valor>`).
    @AppStorage("kurth.blurRadius") private var blurRadius = 9.0
    @AppStorage("kurth.blurSaturation") private var blurSaturation = 1.6
    /// Opacidad de la capa de color en "tinted" al hacer scroll (1 = sólido, 0 = solo blur).
    @AppStorage("kurth.tintOpacity") private var tintOpacity = 0.72
    /// Línea de 1 px físico bajo la barra cuando la página ya se desplazó. 0 la quita.
    @AppStorage("kurth.hairline") private var hairlineOpacity = 0.1
    /// En "capsules", blur detrás de las cápsulas. Apagado: el Liquid Glass ya separa la barra
    /// de la página, y la página pasa nítida. Se cambia con clic derecho en la barra.
    @AppStorage("kurth.capsuleBlur") private var capsuleBlur = false
    /// En "capsules", capa ligera del color del sitio dentro del vidrio, para legibilidad.
    @AppStorage("kurth.capsuleTintOpacity") private var capsuleTintOpacity = 0.35

    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0
    @State private var didCopy = false
    @State private var isHoveringAddress = false

    private var isCapsules: Bool { barStyle != "tinted" }

    /// Con cápsulas de 30 pt, 46 deja 8 pt arriba y abajo; en "tinted" basta con 40.
    private var barHeight: CGFloat { isCapsules ? 46 : KurthChrome.topBarHeight }

    var body: some View {
        let sideWidth = max(leadingWidth, trailingWidth)

        HStack(spacing: 0) {
            leadingControls
                .modifier(KurthCapsule(active: isCapsules, tint: glassTint))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
                .frame(width: sideWidth, alignment: .leading)

            address
                .frame(maxWidth: .infinity)

            trailingControls
                .modifier(KurthCapsule(active: isCapsules, tint: glassTint))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
                .frame(width: sideWidth, alignment: .trailing)
        }
        .padding(.horizontal, NookDesign.Spacing.sm)
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) { barBackground }
        .background(
            KurthBarProbe(showsWindowButtons: showsWindowButtons)
        )
        .environment(\.colorScheme, pageScheme ?? systemScheme)
        .animation(NookDesign.Motion.standard, value: pageScheme)
        .animation(NookDesign.Motion.standard, value: barStyle)
    }

    // MARK: - Fondo

    /// Hasta arriba, la barra es del color de la página y se funde con ella. Al hacer scroll la
    /// página pasa por debajo desenfocada: sola en "capsules", con una capa de su color en "tinted".
    private var barBackground: some View {
        ZStack(alignment: .top) {
            if showsBlur {
                KurthBackdropBlur(radius: blurRadius, saturation: blurSaturation, fade: 0)
                    .frame(height: barHeight)
                    .clipShape(topCorners)
                    .allowsHitTesting(false)
            }

            topCorners
                .fill(Color(nsColor: pageColor ?? .windowBackgroundColor))
                .frame(height: barHeight)
                .opacity(colorOpacity)
                .allowsHitTesting(false)

            Rectangle()
                .fill(.primary.opacity(hairlineOpacity))
                .frame(height: 1 / displayScale)
                .frame(height: barHeight, alignment: .bottom)
                // Sin superficie de barra (cápsulas sin blur) la línea cortaría la página.
                .opacity(isAtTop || !showsBlur ? 0 : 1)
                .allowsHitTesting(false)

            // Capa invisible que atrapa el clic en el fondo: arrastra la ventana en vez de
            // que pase a la página de abajo, y trae el selector de variante.
            Color.clear
                .frame(height: barHeight)
                .contentShape(Rectangle())
                .backgroundDraggable()
                .contextMenu {
                    Picker("Estilo de barra", selection: $barStyle) {
                        Text("Cápsulas (tipo Safari)").tag("capsules")
                        Text("Color del sitio").tag("tinted")
                    }
                    .pickerStyle(.inline)
                    if isCapsules {
                        Divider()
                        Toggle("Blur detrás de las cápsulas", isOn: $capsuleBlur)
                    }
                }
        }
        .animation(.easeOut(duration: 0.18), value: isAtTop)
    }

    private var showsBlur: Bool { !isCapsules || capsuleBlur }

    /// Con la capa del sitio las cápsulas se leen mejor, salvo cuando la página tiene encabezado
    /// fijo (YouTube): ahí quedan pegadas a él y el vidrio puro se ve mejor que la capa encima.
    private var glassTint: Color? {
        guard let pageColor, pageState?.hasTopHeader != true else { return nil }
        return Color(nsColor: pageColor).opacity(capsuleTintOpacity)
    }

    private var colorOpacity: Double {
        if isAtTop { return 1 }
        return isCapsules ? 0 : tintOpacity
    }

    private var topCorners: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: NookDesign.Radius.md, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: NookDesign.Radius.md,
            style: .continuous
        )
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

            // Adelante solo existe cuando hay a dónde ir.
            if session?.canGoForward == true {
                Button("Go Forward", systemImage: "chevron.forward") {
                    if let webView = windowWebView { webView.goForward() } else { session?.goForward() }
                }
                .kurthBarIcon()
                .contextMenu {
                    NavigationHistoryContextMenu(historyType: .forward, windowState: windowState)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            // En "tinted" recargar va junto a las flechas; en "capsules", dentro de la cápsula.
            if !isCapsules {
                reloadButton.kurthBarIcon()
            }
        }
        .animation(NookDesign.Motion.quick, value: session?.canGoForward)
    }

    // MARK: - Centro: dominio y copiar

    @ViewBuilder
    private var address: some View {
        if let tab = browserManager.tabs.selectedSession(in: windowState) {
            if isCapsules {
                // Cápsula: el dominio centrado y los íconos anclados a las orillas, no al texto.
                // Mide lo que ocupa el dominio (mínimo `addressMinWidth`) y crece si es largo.
                hostText(tab)
                    .padding(.horizontal, Self.capsuleInset + 20 + NookDesign.Spacing.lg)
                    .frame(minWidth: Self.addressMinWidth)
                    .frame(height: 30)
                    .overlay(alignment: .leading) {
                        copyButton(tab).padding(.leading, Self.capsuleInset)
                    }
                    .overlay(alignment: .trailing) {
                        reloadButton.kurthFieldIcon().padding(.trailing, Self.capsuleInset)
                    }
                    .modifier(KurthGlass(tint: glassTint))
            } else {
                // Copiar junto al dominio; recargar vive con las flechas en esta variante.
                HStack(spacing: NookDesign.Spacing.md + 2) {
                    copyButton(tab)
                    hostText(tab)
                }
                .padding(.horizontal, NookDesign.Spacing.md)
            }
        }
    }

    static let addressMinWidth: CGFloat = 130
    /// Aire entre los íconos y la orilla de cada cápsula.
    static let capsuleInset: CGFloat = 8

    private func hostText(_ tab: PageSession) -> some View {
        Text(Self.shortHost(tab.url))
            .font(NookDesign.Font.body)
            .foregroundStyle(isHoveringAddress ? .primary : .secondary)
            .truncationMode(.head)
            .lineLimit(1)
            .contentShape(Rectangle())
            .onTapGesture { commandPalette.openWithCurrentURL(tab.url) }
            .onHoverTracking { isHoveringAddress = $0 }
    }

    private func copyButton(_ tab: PageSession) -> some View {
        Button("Copiar URL", systemImage: didCopy ? "checkmark" : "link") {
            copyURL(tab.url)
        }
        .kurthFieldIcon()
        .help("Copiar URL")
    }

    private var reloadButton: Button<Label<Text, Image>> {
        Button(session?.isLoading == true ? "Detener" : "Recargar",
               systemImage: session?.isLoading == true ? "xmark" : "arrow.clockwise") {
            if session?.isLoading == true { session?.stop() } else { session?.refresh() }
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
                Button("Chat", systemImage: "text.bubble") {
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

    private var pageState: KurthPageState? {
        windowWebView.map(KurthPageState.of)
    }

    private var isAtTop: Bool { pageState?.isAtTop ?? true }

    /// El color de la parte alta de la página: el que muestrea WebKit (como Safari) y, si no hay,
    /// el que ya calcula Nook.
    private var pageColor: NSColor? {
        if let color = pageState?.topColor { return color }
        let tab = browserManager.tabs.selectedSession(in: windowState)
        return tab?.pageBackgroundColor ?? tab?.topBarBackgroundColor
    }

    /// Íconos grises claros u oscuros según lo que haya detrás.
    private var pageScheme: ColorScheme? {
        pageColor.map { $0.isPerceivedDark ? .dark : .light }
    }

    /// Semáforos solo con barra lateral a la vista: la fija o la que sale al pasar por el borde.
    private var showsWindowButtons: Bool {
        windowState.isSidebarVisible || hoverSidebarManager.isOverlayVisible
    }
}

private extension View {
    func kurthBarIcon() -> some View {
        self
            .labelStyle(.iconOnly)
            .buttonStyle(KurthBarButtonStyle())
            .foregroundStyle(.secondary)
    }

    /// Íconos dentro del campo de la URL: mismo gris, un poco más chicos.
    func kurthFieldIcon() -> some View {
        self
            .labelStyle(.iconOnly)
            .font(NookDesign.Font.caption)
            .buttonStyle(KurthBarButtonStyle(size: 20))
            .foregroundStyle(.secondary)
    }
}

/// Como NookIconButtonStyle, con el label en el gris que le pone la barra.
private struct KurthBarButtonStyle: ButtonStyle {
    var size: CGFloat = NookDesign.Size.iconButton
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            NookDesign.Radius.shape(NookDesign.Radius.md)
                .fill(fill(isPressed: configuration.isPressed))
                .frame(width: size, height: size)
            configuration.label
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        // Atrás sin historial se ve suspendido; el resto de los íconos va en el mismo gris.
        .opacity(isEnabled ? 1 : 0.35)
        .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1.0)
        .animation(NookDesign.Motion.quick, value: configuration.isPressed)
        .animation(NookDesign.Motion.quick, value: isHovering)
        .onHoverTracking { isHovering = $0 }
    }

    private func fill(isPressed: Bool) -> Color {
        guard isEnabled else { return .clear }
        if isPressed { return NookDesign.Surface.fillPressed }
        if isHovering { return NookDesign.Surface.fill }
        return .clear
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

// MARK: - Cápsula de Liquid Glass

/// En la variante tipo Safari, cada grupo de la barra va en su cápsula de vidrio.
private struct KurthCapsule: ViewModifier {
    let active: Bool
    var minWidth: CGFloat = 0
    var tint: Color? = nil

    func body(content: Content) -> some View {
        if active {
            content
                .padding(.horizontal, KurthTopBarView.capsuleInset - 2)
                // Los grupos de botones miden lo que miden: un marco flexible con ancho 0
                // los dejaba en 0 y la cápsula los recortaba hasta desaparecer.
                .fixedSize(horizontal: minWidth == 0, vertical: false)
                .frame(minWidth: minWidth == 0 ? nil : minWidth)
                .frame(height: 30)
                .modifier(KurthGlass(tint: tint))
        } else {
            content
        }
    }
}

/// nookGlassEffect con tinte opcional: el vidrio toma un poco del color del sitio sin volverse
/// sólido. Sin tinte es idéntico al de Nook.
private struct KurthGlass: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .clipShape(Capsule())
            .glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: Capsule())
            .nookElevation(.floating)
    }
}
