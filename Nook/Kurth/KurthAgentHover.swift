// Licensed under GPL-3.0. See LICENSE.
//
//  KurthAgentHover.swift
//  Nook (rama kurth)
//
//  El panel del agente también se asoma al pasar el mouse por su orilla cuando está cerrado, como
//  la barra lateral principal (Kurth, 24 sep: "que todo el sidebar del agente pueda ser hover
//  también"). Calca HoverSidebarManager + SidebarHoverOverlayView para la orilla contraria, con
//  tres diferencias por ser un chat:
//   · No roba el foco del teclado al asomarse (si estás escribiendo en la página, no te interrumpe).
//   · No se esconde mientras haya un borrador sin mandar, un permiso esperando o el agente trabajando.
//   · Pide una pausa corta en la orilla antes de abrir: ahí mismo vive la barra de scroll de la
//     página, y con el botón del mouse apretado (arrastrando el scroll) no abre.
//  No hay franja invisible sobre la página: los monitores de NSEvent ya detectan la orilla, y una
//  vista ahí se comería los clics a la barra de scroll.
//
//  Desde el 25 sep es una tarjeta, no una columna (Kurth: "más bello con el glass… y que no tenga
//  todo el alto de la ventana sino la mitad"): mitad del alto, abajo en la esquina, con el campo de
//  texto donde lo tiene el panel fijo, y Liquid Glass como las cápsulas de la barra. La barra
//  lateral flotante sigue con el material del panel fijo; esta ya no es una barra lateral.
//  Se abre y se queda abierta en la misma franja que antes, de todo el alto: si solo contara la
//  tarjeta, al abrirla desde arriba de la orilla se cerraba antes de que el mouse bajara a ella.
//
//  Después (Kurth, 25 sep): la orilla de arriba se arrastra para cambiar el alto, sin llegar a la
//  barra de arriba; un pin la deja abierta aunque el mouse se vaya; y un switch en el encabezado
//  alterna entre el vidrio y el material del panel fijo, para comparar. Los tres son ajustes
//  kurth.agentCard* (en el MCP y en la sincronización de iCloud).
//

import AppKit
import SwiftUI
import NookDesign
import NookSettings
import NookWeb
import NookUI

final class KurthAgentHoverManager: ObservableObject {
    @Published var isOverlayVisible = false

    /// Mientras se arrastra la orilla del panel flotante no se esconde (AISidebarResizeView).
    @MainActor static var redimensionando = false
    /// Hay texto escrito sin mandar en el panel flotante (KurthAgentChat lo mantiene al día).
    @MainActor static var conBorrador = false
    /// Fijada con el pin del encabezado: se queda abierta aunque el mouse se vaya.
    static let claveFijada = "kurth.agentCardPinned"
    static var fijada: Bool { UserDefaults.standard.bool(forKey: claveFijada) }

    weak var browserManager: BrowserManager?
    weak var windowRegistry: WindowRegistry?
    weak var nookSettings: NookSettingsService?
    weak var agente: KurthAgentService?

    /// Mismas medidas que HoverSidebarManager.
    let triggerWidth: CGFloat = 6
    let overshootSlack: CGFloat = 12
    let keepOpenHysteresis: CGFloat = 52
    let verticalSlack: CGFloat = 24
    let keepOpenOutsideSlack: CGFloat = 200
    let keepOpenVerticalSlack: CGFloat = 100
    /// Pausa en la orilla antes de abrir.
    let pausa: TimeInterval = 0.2

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var isActive = false
    private var pendingHide: DispatchWorkItem?
    private var enLaOrillaDesde: Date?

    func reveal() {
        pendingHide?.cancel()
        pendingHide = nil
        if !isOverlayVisible { isOverlayVisible = true }
    }

    func scheduleHide() {
        guard isOverlayVisible, pendingHide == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingHide = nil
            self?.isOverlayVisible = false
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + KurthMotion.hoverGrace, execute: work)
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.programar()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            self?.programar()
        }
    }

    func stop() {
        isActive = false
        if let token = localMonitor { NSEvent.removeMonitor(token); localMonitor = nil }
        if let token = globalMonitor { NSEvent.removeMonitor(token); globalMonitor = nil }
        DispatchQueue.main.async { [weak self] in self?.isOverlayVisible = false }
    }

    deinit { stop() }

    /// Vuelve a decidir sin esperar a que se mueva el mouse (al quitar el pin).
    func revisarAhora() { programar() }

    private func programar() {
        DispatchQueue.main.async { [weak self] in self?.revisar() }
    }

    @MainActor
    private func revisar() {
        guard browserManager != nil, let registry = windowRegistry, let estado = registry.activeWindow else { return }

        // Con el panel fijo a la vista, el flotante no existe.
        if estado.isSidebarAIChatVisible {
            if isOverlayVisible { isOverlayVisible = false }
            return
        }

        if Self.fijada {
            reveal()
            return
        }

        // Abierto y con algo a medias, se queda aunque el mouse se vaya.
        if isOverlayVisible, Self.redimensionando || Self.conBorrador || agente?.permiso != nil || agente?.estado == .trabajando {
            reveal()
            return
        }

        guard let window = NSApp.keyWindow else {
            if isOverlayVisible { isOverlayVisible = false }
            return
        }

        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        let vSlack = isOverlayVisible ? keepOpenVerticalSlack : verticalSlack
        guard mouse.y >= frame.minY - vSlack, mouse.y <= frame.maxY + vSlack else {
            enLaOrillaDesde = nil
            scheduleHide()
            return
        }

        let ancho = estado.aiSidebarWidth
        let inTriggerZone: Bool, inKeepOpenZone: Bool, inContentZone: Bool
        if nookSettings?.sidebarPosition == .left {
            // El agente vive en la orilla derecha.
            let borde = frame.maxX
            inTriggerZone = mouse.x >= borde - triggerWidth - overshootSlack && mouse.x <= borde + overshootSlack
            inKeepOpenZone = mouse.x >= borde - ancho - keepOpenHysteresis && mouse.x <= borde + keepOpenOutsideSlack
            inContentZone = mouse.x >= borde - ancho && mouse.x <= borde
        } else {
            let borde = frame.minX
            inTriggerZone = mouse.x >= borde - overshootSlack && mouse.x <= borde + triggerWidth
            inKeepOpenZone = mouse.x >= borde - keepOpenOutsideSlack && mouse.x <= borde + ancho + keepOpenHysteresis
            inContentZone = mouse.x >= borde && mouse.x <= borde + ancho
        }

        if isOverlayVisible {
            if inTriggerZone || inKeepOpenZone || inContentZone { reveal() } else { scheduleHide() }
            return
        }

        // Cerrado: abre tras la pausa en la orilla, y nunca con un botón apretado (scroll arrastrado).
        guard inTriggerZone, NSEvent.pressedMouseButtons == 0 else {
            enLaOrillaDesde = nil
            return
        }
        if let desde = enLaOrillaDesde {
            if Date().timeIntervalSince(desde) >= pausa { reveal() }
        } else {
            enLaOrillaDesde = Date()
            // El mouse quieto no manda eventos: se vuelve a revisar cuando venza la pausa.
            DispatchQueue.main.asyncAfter(deadline: .now() + pausa + 0.02) { [weak self] in self?.revisar() }
        }
    }
}

/// El panel flotante: el mismo KurthAgentChat en una tarjeta de vidrio, abajo en la orilla del
/// agente, con su ancho guardado y la orilla arrastrable.
struct KurthAgentHoverOverlay: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(WindowRegistry.self) private var windowRegistry
    @Environment(KurthAgentService.self) private var agente
    @Environment(\.nookSettings) var nookSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hover = KurthAgentHoverManager()

    private var enLaDerecha: Bool { nookSettings.sidebarPosition == .left }

    /// El alto, como fracción del alto de la ventana: así queda proporcional en la Air y en la Pro.
    @AppStorage("kurth.agentCardHeight") private var fraccion = 0.5
    /// Mientras se arrastra la orilla de arriba; se guarda al soltar.
    @State private var fraccionEnVivo: Double?
    @AppStorage("kurth.agentCardMaterial") private var material = "glass"
    @AppStorage(KurthAgentHoverManager.claveFijada) private var fijada = false

    /// Entre 360 pt (el campo, los controles y un par de mensajes) y la orilla de abajo de la barra
    /// de arriba (44 pt con cápsulas) más la separación: la tarjeta nunca la tapa (Kurth, 25 sep).
    static func limitar(_ alto: CGFloat, en altoDeVentana: CGFloat) -> CGFloat {
        let maximo = altoDeVentana - 44 - 2 * KurthChrome.overlayInset
        return min(maximo, max(min(360, maximo), alto))
    }

    /// Cuánto del tema va sobre el vidrio. El tema solo ya es casi opaco (0.75, KurthTheme.opacity)
    /// y taparía el vidrio; sin nada, el texto largo se pierde sobre una página movida.
    static let velo = 0.55

    var body: some View {
        GeometryReader { ventana in
        let altoDeVentana = ventana.size.height
        let alto = Self.limitar(altoDeVentana * (fraccionEnVivo ?? fraccion), en: altoDeVentana)
        ZStack(alignment: enLaDerecha ? .bottomTrailing : .bottomLeading) {
            if !windowState.isSidebarAIChatVisible, hover.isOverlayVisible {
                KurthAgentChat(flotante: true)
                    .frame(width: windowState.aiSidebarWidth, height: alto)
                    .environmentObject(browserManager)
                    .environment(windowState)
                    .environment(nookSettings)
                    .modifier(KurthAgentCardMaterial(vidrio: material != "panel"))
                    .alwaysArrowCursor(leavingFree: [enLaDerecha ? .minXEdge : .maxXEdge, .maxYEdge], width: 14)
                    .overlay(alignment: enLaDerecha ? .leading : .trailing) {
                        AISidebarResizeView(kurthEnFlotante: true)
                            .frame(maxHeight: .infinity)
                            .environmentObject(browserManager)
                            .environment(windowState)
                    }
                    .overlay(alignment: .top) {
                        KurthAgentCardAltura(alto: alto) { nuevo, soltado in
                            let f = Double(Self.limitar(nuevo, en: altoDeVentana) / max(altoDeVentana, 1))
                            if soltado {
                                fraccion = f
                                fraccionEnVivo = nil
                            } else {
                                fraccionEnVivo = f
                            }
                        }
                    }
                    .padding(enLaDerecha ? .trailing : .leading, KurthChrome.overlayInset)
                    .padding(.bottom, KurthChrome.overlayInset)
                    .transition(.move(edge: enLaDerecha ? .trailing : .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: enLaDerecha ? .bottomTrailing : .bottomLeading)
        }
        .animation(KurthMotion.respecting(reduceMotion, hover.isOverlayVisible ? KurthMotion.reveal : KurthMotion.dismiss),
                   value: hover.isOverlayVisible)
        .onAppear {
            hover.browserManager = browserManager
            hover.windowRegistry = windowRegistry
            hover.nookSettings = nookSettings
            hover.agente = agente
            hover.start()
        }
        .onDisappear { hover.stop() }
        .onChange(of: windowState.isSidebarAIChatVisible) { _, fijo in
            if fijo { hover.isOverlayVisible = false } else if fijada { hover.reveal() }
        }
        .onChange(of: fijada) { _, ahora in
            if ahora { hover.reveal() } else { hover.revisarAhora() }
        }
    }
}

/// Vidrio (Liquid Glass con el tema encima, a `velo`) o el material del panel fijo (el mismo que la
/// barra lateral flotante): el switch del encabezado alterna para comparar.
private struct KurthAgentCardMaterial: ViewModifier {
    let vidrio: Bool

    func body(content: Content) -> some View {
        if vidrio {
            content
                .background { KurthHoverTheme(soloTema: true).opacity(KurthAgentHoverOverlay.velo) }
                .clipShape(KurthChrome.overlayShape)
                .glassEffect(.regular, in: KurthChrome.overlayShape)
                .nookElevation(.floating)
        } else {
            content
                .background { KurthHoverTheme() }
                .clipShape(KurthChrome.overlayShape)
                .nookElevation(.floating)
        }
    }
}

/// La orilla de arriba de la tarjeta: se arrastra para cambiar el alto, con la misma línea de acento
/// que la orilla del ancho (AISidebarResizeView). Mientras se arrastra, el hover no la esconde.
private struct KurthAgentCardAltura: View {
    let alto: CGFloat
    /// El alto nuevo; `true` al soltar, para guardarlo.
    let cambiar: (CGFloat, Bool) -> Void

    @State private var encima = false
    @State private var altoAlEmpezar: CGFloat?

    var body: some View {
        ZStack(alignment: .top) {
            if encima || altoAlEmpezar != nil {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 30)
                    .padding(.top, 1)
                    .transition(.opacity)
            }
            Color.clear
                .frame(height: 8)
                .padding(.horizontal, 30)
                .contentShape(Rectangle())
                .onHoverTracking { dentro in
                    encima = dentro
                    if dentro { NSCursor.resizeUpDown.set() } else if altoAlEmpezar == nil { NSCursor.arrow.set() }
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { valor in
                            if altoAlEmpezar == nil {
                                altoAlEmpezar = alto
                                KurthAgentHoverManager.redimensionando = true
                            }
                            // La orilla sube con el mouse: hacia arriba (translation negativa) crece.
                            cambiar((altoAlEmpezar ?? alto) - valor.translation.height, false)
                            NSCursor.resizeUpDown.set()
                        }
                        .onEnded { valor in
                            cambiar((altoAlEmpezar ?? alto) - valor.translation.height, true)
                            altoAlEmpezar = nil
                            KurthAgentHoverManager.redimensionando = false
                            if !encima { NSCursor.arrow.set() }
                        }
                )
        }
        .animation(NookDesign.Motion.quick, value: encima)
    }
}
