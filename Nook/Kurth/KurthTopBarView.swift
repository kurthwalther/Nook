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
    /// Tamaño de la barra (KurthEscala); aquí solo para que la vista se redibuje al cambiarlo.
    @AppStorage("kurth.barScale") private var barScale = 1.0
    /// Pestañas: "separate" (solo en la barra lateral) o "compact" (en la barra, como Safari 15).
    @AppStorage("kurth.tabLayout") private var tabLayout = "separate"
    /// En compact, "titles" (ícono y título) o "icons" (solo ícono, como iPad).
    @AppStorage("kurth.compactTabs") private var compactTabs = "titles"

    /// Barra inmersiva: escondida hasta que el mouse llega a la orilla de arriba; entonces baja y
    /// flota sobre la página sin reservarle espacio, así la página no brinca (Kurth, 25 sep: "que se
    /// oculte y se muestre con hover, para que sea full immersive").
    @AppStorage("kurth.barAutoHide") private var autoHide = false
    @State private var inmersiva = KurthBarraInmersiva()

    @State private var showsRadiusPanel = false
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0
    @State private var didCopy = false
    @State private var isHoveringAddress = false
    /// El mouse está sobre la cápsula del dominio: ahí aparece el ícono de copiar (Kurth, 25 sep).
    @State private var isHoveringCapsule = false

    private var isCapsules: Bool { barStyle != "tinted" }
    private var isCompact: Bool { tabLayout == "compact" }

    /// Con cápsulas de 28 pt, 44 deja 8 pt arriba y abajo, igual que a los lados; en "tinted" 40.
    private var barHeight: CGFloat { isCapsules ? KurthEscala.pt(44) : KurthChrome.topBarHeight }
    /// Separación de las cápsulas con la orilla de la página: la misma arriba y al lado (8/8),
    /// que es el equilibrio que queda cuando una cápsula no puede ser concéntrica con la esquina.
    private var sidePadding: CGFloat { KurthEscala.pt(isCapsules ? 8 : NookDesign.Spacing.sm) }
    private var iconSize: CGFloat { KurthEscala.pt(isCapsules ? 24 : NookDesign.Size.iconButton) }

    var body: some View {
        ZStack(alignment: .top) {
            barra
                .offset(y: seMuestra ? 0 : -(barHeight + 6))
                .opacity(seMuestra ? 1 : 0)
                .allowsHitTesting(seMuestra)
        }
        .animation(.spring(duration: 0.28, bounce: 0.08), value: seMuestra)
        // Cuándo baja la barra lo decide KurthBarraInmersiva, con la posición del mouse contra la
        // ventana (una franja de SwiftUI no recibía el hover bajo la zona de la barra de título).
        .onChange(of: autoHide, initial: true) { _, activo in
            inmersiva.altoDeBarra = barHeight
            if activo { inmersiva.encender(en: windowState) } else { inmersiva.apagar() }
        }
        .onDisappear { inmersiva.apagar() }
    }

    /// Siempre, salvo en modo inmersivo; ahí, con el mouse encima, con el panel de opciones o el del
    /// radio abiertos, o sin página (la barra es lo único que hay).
    private var seMuestra: Bool {
        !autoHide || inmersiva.visible || !hasPage || windowState.isExtensionLibraryVisible || showsRadiusPanel
    }

    private var barra: some View {
        let sideWidth = max(leadingWidth, trailingWidth)

        return HStack(spacing: 0) {
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
        .padding(.horizontal, sidePadding)
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) { barBackground }
        .background(
            // En modo inmersivo la barra no reserva espacio: flota sobre la página (sin inset).
            KurthBarProbe(showsWindowButtons: showsWindowButtons && seMuestra, reservaEspacio: !autoHide)
        )
        .environment(\.colorScheme, pageScheme ?? systemScheme)
        .animation(NookDesign.Motion.standard, value: pageScheme)
        .animation(NookDesign.Motion.standard, value: barStyle)
        .animation(NookDesign.Motion.standard, value: tabLayout)
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

            // Encabezado fijo que WebKit no rellena porque no va de orilla a orilla: la franja
            // toma su color para que la página no se asome entre la barra y él (Kurth, 25 sep).
            topCorners
                .fill(Color(nsColor: headerFill ?? .clear))
                .frame(height: barHeight)
                .opacity(headerFill == nil ? 0 : 1)
                .allowsHitTesting(false)
                // Hasta arriba (la página cargando) el color entra de golpe, con la página; el fundido
                // queda para cuando aparece un menú fijo al hacer scroll.
                .animation(isAtTop ? nil : .easeOut(duration: 0.15), value: headerFill)

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
                .popover(isPresented: $showsRadiusPanel, arrowEdge: .bottom) {
                    KurthRadiusPanel()
                }
                .contextMenu {
                    KurthBarSettingsMenu()
                    Button("Radio de la página… (\(Int(KurthPrefs.shared.pageRadius)) pt)") {
                        showsRadiusPanel = true
                    }
                }
        }
        .animation(.easeOut(duration: 0.18), value: isAtTop)
    }

    private var showsBlur: Bool { hasPage && (!isCapsules || capsuleBlur) }

    /// El color del encabezado pegado arriba según el script (KurthPageState.scriptHeaderColor): el
    /// de su CSS, exacto. Manda aunque WebKit también lo vea, porque WebKit muestrea pixeles y le
    /// sale apenas gris: en ultrajewels la franja medía #FCFCFC contra el #FFFFFF de la página y de
    /// lado a lado se veía un escalón, como sombra bajo la barra (Kurth, 25 sep).
    private var headerFill: NSColor? {
        // En modo inmersivo la barra flota sobre la página: sin franja de color debajo.
        guard hasPage, !autoHide else { return nil }
        return pageState?.scriptHeaderColor
    }

    /// Con la capa del sitio las cápsulas se leen mejor, salvo cuando la página tiene encabezado
    /// fijo (YouTube): ahí quedan pegadas a él y el vidrio puro se ve mejor que la capa encima.
    private var glassTint: Color? {
        guard let pageColor, pageState?.hasTopHeader != true else { return nil }
        return Color(nsColor: pageColor).opacity(capsuleTintOpacity)
    }

    private var hasPage: Bool { browserManager.tabs.selectedSession(in: windowState) != nil }

    private var colorOpacity: Double {
        // Sin pestaña no hay página que tapar: la barra deja ver el tema. En modo inmersivo flota
        // sobre la página, sin franja.
        guard hasPage, !autoHide else { return 0 }
        if isAtTop { return 1 }
        return isCapsules ? 0 : tintOpacity
    }

    /// Las esquinas de arriba de la tarjeta, concéntricas con la ventana; rectas abajo.
    private var topCorners: ConcentricRectangle { KurthChrome.pageTopShape }

    // MARK: - Izquierda: barra lateral, atrás, adelante, recargar

    private var leadingControls: some View {
        HStack(spacing: NookDesign.Spacing.xxs) {
            Button("Toggle Sidebar", systemImage: nookSettings.sidebarPosition == .left ? "sidebar.left" : "sidebar.right") {
                browserManager.toggleSidebar(for: windowState)
            }
            .kurthBarIcon(size: iconSize)

            // Sin página no hay a dónde ir ni qué recargar: solo queda el botón del sidebar.
            if hasPage {
                Button("Go Back", systemImage: "chevron.backward") {
                    if let webView = windowWebView { webView.goBack() } else { session?.goBack() }
                }
                .kurthBarIcon(size: iconSize)
                .disabled(!(session?.canGoBack ?? false))
                .contextMenu {
                    NavigationHistoryContextMenu(historyType: .back, windowState: windowState)
                }

                // Adelante solo existe cuando hay a dónde ir.
                if session?.canGoForward == true {
                    Button("Go Forward", systemImage: "chevron.forward") {
                        if let webView = windowWebView { webView.goForward() } else { session?.goForward() }
                    }
                    .kurthBarIcon(size: iconSize)
                    .contextMenu {
                        NavigationHistoryContextMenu(historyType: .forward, windowState: windowState)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                // En "tinted" recargar va junto a las flechas; en "capsules", dentro de la cápsula.
                if !isCapsules {
                    reloadButton.kurthBarIcon(size: iconSize)
                }
            }
        }
        .animation(NookDesign.Motion.quick, value: session?.canGoForward)
    }

    // MARK: - Centro: dominio y copiar

    @ViewBuilder
    private var address: some View {
        if let tab = browserManager.tabs.selectedSession(in: windowState) {
            if isCompact {
                // Pestañas compactas (KurthTabStrip.swift): la tira ocupa todo el centro.
                KurthTabStrip(glass: isCapsules, tint: glassTint, iconsOnly: compactTabs == "icons")
                    .padding(.horizontal, isCapsules ? 8 : NookDesign.Spacing.md)
                    // La tira publica su cápsula si todas caben; si se desplaza por dentro, no se
                    // desliza entre pestañas: ahí el gesto mueve la tira (KurthGestosDePestanas).
                    .onPreferenceChange(KurthZonaDeDeslizar.self) { zona in
                        MainActor.assumeIsolated { KurthGestos.de(windowState).zonaDeDeslizar = zona }
                    }
            } else if isCapsules {
                // Cápsula: el dominio centrado y los íconos anclados a las orillas, no al texto.
                // Mide lo que ocupa el dominio (mínimo `addressMinWidth`) y crece si es largo.
                hostText(tab)
                    .padding(.horizontal, Self.capsuleInset + KurthEscala.pt(20) + NookDesign.Spacing.lg)
                    .frame(minWidth: Self.addressMinWidth)
                    .frame(height: Self.capsuleHeight)
                    .overlay(alignment: .leading) {
                        copyButton(tab).padding(.leading, Self.capsuleInset)
                    }
                    .overlay(alignment: .trailing) {
                        reloadButton.kurthFieldIcon().padding(.trailing, Self.capsuleInset)
                    }
                    .modifier(KurthGlass(tint: glassTint))
                    .onHoverTracking { isHoveringCapsule = $0 }
                    .modifier(KurthZonaDeDeslizarAqui())
            } else {
                // Copiar junto al dominio; recargar vive con las flechas en esta variante.
                HStack(spacing: NookDesign.Spacing.md + 2) {
                    copyButton(tab)
                    hostText(tab)
                }
                .padding(.horizontal, NookDesign.Spacing.md)
                .onHoverTracking { isHoveringCapsule = $0 }
                .modifier(KurthZonaDeDeslizarAqui())
            }
        } else {
            // Sin pestaña, el espacio de la URL es un campo listo para escribir (KurthEmptyPage.swift).
            // Además ocupa el centro: vacío, SwiftUI le ignoraba el .frame(maxWidth: .infinity) y los
            // botones se juntaban en medio.
            if isCapsules {
                KurthAddressInput().modifier(KurthGlass(tint: glassTint))
            } else {
                KurthAddressInput().background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
    }

    /// Medidas base de la barra, a la escala de KurthEscala (normal 130 / 28 / 8).
    static var addressMinWidth: CGFloat { KurthEscala.pt(130) }
    static var capsuleHeight: CGFloat { KurthEscala.pt(28) }
    /// Aire entre los íconos y la orilla de cada cápsula.
    static var capsuleInset: CGFloat { KurthEscala.pt(8) }

    private func hostText(_ tab: PageSession) -> some View {
        Text(Self.shortHost(tab.url))
            .font(KurthEscala.fuente(13))
            .foregroundStyle(isHoveringAddress ? .primary : .secondary)
            .truncationMode(.head)
            .lineLimit(1)
            .contentShape(Rectangle())
            .onTapGesture { commandPalette.openWithCurrentURL(tab.url) }
            .onHoverTracking { isHoveringAddress = $0 }
    }

    /// Solo al pasar el mouse por la cápsula (o mientras muestra la palomita); el hueco se queda
    /// para que el dominio no se mueva. ⌘⇧C hace lo mismo.
    private func copyButton(_ tab: PageSession) -> some View {
        Button("Copiar URL", systemImage: didCopy ? "checkmark" : "link") {
            copyURL(tab.url)
        }
        .kurthFieldIcon()
        .opacity(isHoveringCapsule || didCopy ? 1 : 0)
        .allowsHitTesting(isHoveringCapsule || didCopy)
        .animation(NookDesign.Motion.quick, value: isHoveringCapsule)
        .help("Copiar URL (⌘⇧C)")
    }

    /// Recargar, cargando (gira) o detener (X, solo al pasar el mouse): KurthReloadButton.swift.
    private var reloadButton: some View { KurthReloadButton(session: session) }

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
                    // Si la capa del panel lo acaba de cerrar con este mismo clic, no reabrir
                    // (ver ExtensionLibraryOverlay.cerradoEn).
                    if windowState.isExtensionLibraryVisible {
                        windowState.isExtensionLibraryVisible = false
                    } else if Date().timeIntervalSince(ExtensionLibraryOverlay.cerradoEn) > 0.3 {
                        windowState.isExtensionLibraryVisible = true
                    }
                }
                .kurthBarIcon(size: iconSize)
                // El panel de extensiones de WindowView se cuelga de este marco.
                .anchorPreference(key: ExtensionLibraryAnchorKey.self, value: .bounds) { $0 }
            }

            if nookSettings.showAIAssistant {
                Button("Chat", systemImage: "text.bubble") {
                    browserManager.toggleAISidebar(for: windowState)
                }
                .kurthBarIcon(size: iconSize)
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
        // Con la franja del encabezado pintada, los íconos van sobre su color.
        (headerFill ?? pageColor).map { $0.isPerceivedDark ? .dark : .light }
    }

    /// Semáforos solo con barra lateral a la vista: la fija o la que sale al pasar por el borde.
    private var showsWindowButtons: Bool {
        windowState.isSidebarVisible || hoverSidebarManager.isOverlayVisible
    }
}

extension View {
    func kurthBarIcon(size: CGFloat = NookDesign.Size.iconButton) -> some View {
        self
            .labelStyle(.iconOnly)
            .buttonStyle(KurthBarButtonStyle(size: size))
            .foregroundStyle(.secondary)
    }

    /// Íconos dentro del campo de la URL: mismo gris, un poco más chicos.
    func kurthFieldIcon() -> some View {
        self
            .labelStyle(.iconOnly)
            .font(KurthEscala.fuente(11))
            .buttonStyle(KurthBarButtonStyle(size: KurthEscala.pt(20)))
            .foregroundStyle(.secondary)
    }
}

/// Como NookIconButtonStyle, con el label en el gris que le pone la barra.
struct KurthBarButtonStyle: ButtonStyle {
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
    /// Falso en modo inmersivo: la barra no le quita alto a la página (no registra su rectángulo).
    var reservaEspacio = true

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.showsWindowButtons = showsWindowButtons
        view.reservaEspacio = reservaEspacio
        view.sync()
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.detach()
    }

    final class ProbeView: NSView {
        var showsWindowButtons = true
        var reservaEspacio = true
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
            KurthChrome.setBarRect(reservaEspacio ? rect : nil, in: window)
            setWindowButtons(hidden: !showsWindowButtons, in: window)
        }

        func detach() {
            guard let window = window ?? hostWindow else { return }
            KurthChrome.setBarRect(nil, in: window)
            setWindowButtons(hidden: false, in: window)
            buttonTypes.compactMap { window.standardWindowButton($0) }.forEach { $0.alphaValue = 1 }
        }

        private var buttonsHidden: Bool?

        private func setWindowButtons(hidden: Bool, in window: NSWindow) {
            // En pantalla completa manda FullScreenToolbarView.
            guard !window.styleMask.contains(.fullScreen), hidden != buttonsHidden else { return }
            buttonsHidden = hidden
            let buttons = buttonTypes.compactMap { window.standardWindowButton($0) }
            // Fundido al ritmo de la barra lateral en vez de aparecer de golpe. Ocultos quedan
            // además isHidden: un botón con alfa 0 seguiría recibiendo clics.
            if !hidden { buttons.forEach { $0.alphaValue = 0; $0.isHidden = false } }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = hidden ? 0.15 : 0.21
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                buttons.forEach { $0.animator().alphaValue = hidden ? 0 : 1 }
            } completionHandler: { [weak self] in
                guard self?.buttonsHidden == true else { return }
                buttons.forEach { $0.isHidden = true }
            }
        }
    }
}

// MARK: - Cápsula de Liquid Glass

/// En la variante tipo Safari, cada grupo de la barra va en su cápsula de vidrio.
/// La comparte el encabezado del panel del agente (KurthAgentChat).
struct KurthCapsule: ViewModifier {
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
                .frame(height: KurthTopBarView.capsuleHeight)
                .modifier(KurthGlass(tint: tint))
        } else {
            content
        }
    }
}

/// nookGlassEffect con tinte opcional: el vidrio toma un poco del color del sitio sin volverse
/// sólido. Sin tinte es idéntico al de Nook.
struct KurthGlass: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .clipShape(Capsule())
            .glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: Capsule())
            .nookElevation(.floating)
    }
}

// MARK: - Panel del radio de la página

/// Slider de 8 a 16 para probar el radio de la página en vivo (se abre desde el clic derecho).
private struct KurthRadiusPanel: View {
    var body: some View {
        let prefs = KurthPrefs.shared
        VStack(alignment: .leading, spacing: NookDesign.Spacing.md) {
            HStack {
                Text("Radio de la página")
                    .font(NookDesign.Font.body.weight(.semibold))
                Spacer()
                Text("\(Int(prefs.pageRadius)) pt")
                    .font(NookDesign.Font.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { prefs.pageRadius }, set: { prefs.pageRadius = $0.rounded() }), in: 8...16, step: 1) {
                EmptyView()
            } minimumValueLabel: {
                Text("8").font(NookDesign.Font.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("16").font(NookDesign.Font.caption).foregroundStyle(.secondary)
            }
            Text("8 es el concéntrico: esquina de la ventana (16) − separación (8).")
                .font(NookDesign.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NookDesign.Spacing.xl)
        .frame(width: 280)
    }
}

// MARK: - Menú de ajustes de la barra

/// Lo que sale con clic derecho en la barra y también sobre la tira de pestañas compactas
/// (KurthTabStrip), para que no haya que buscar los extremos (Kurth, 24 sep).
struct KurthBarSettingsMenu: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @AppStorage("kurth.barStyle") private var barStyle = "capsules"
    @AppStorage("kurth.capsuleBlur") private var capsuleBlur = false
    @AppStorage("kurth.tabLayout") private var tabLayout = "separate"
    @AppStorage("kurth.compactTabs") private var compactTabs = "titles"
    @AppStorage("kurth.barAutoHide") private var autoHide = false
    @AppStorage("kurth.barScale") private var barScale = 1.0

    var body: some View {
        Toggle("Ocultar la barra (aparece al pasar el mouse)", isOn: $autoHide)
        Picker("Tamaño de la barra", selection: Binding(
            get: { barScale > 1 ? 1.2 : 1.0 },
            set: { barScale = $0 })) {
            Text("Normal").tag(1.0)
            Text("Grande (20 % más)").tag(1.2)
        }
        Divider()
        Picker("Estilo de barra", selection: $barStyle) {
            Text("Cápsulas (tipo Safari)").tag("capsules")
            Text("Color del sitio").tag("tinted")
        }
        .pickerStyle(.inline)
        if barStyle != "tinted" {
            Divider()
            Toggle("Blur detrás de las cápsulas", isOn: $capsuleBlur)
        }
        Divider()
        Picker("Pestañas", selection: $tabLayout) {
            Text("En la barra lateral").tag("separate")
            Text("Compactas en la barra (tipo Safari)").tag("compact")
        }
        .pickerStyle(.inline)
        if tabLayout == "compact" {
            Toggle("Solo íconos (como iPad)", isOn: Binding(
                get: { compactTabs == "icons" },
                set: { compactTabs = $0 ? "icons" : "titles" }))
        }
        Divider()
        Button("Editar tema…") {
            KurthThemeStore.shared.openPicker(window: windowState, tabs: browserManager.tabs)
        }
        .disabled(windowState.isIncognito || windowState.spaceID == nil)
    }
}
