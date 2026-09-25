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

    /// La mitad del alto, pero no menos de 360 pt: en una ventana baja, el campo, los controles
    /// y un par de mensajes tienen que caber.
    static func alto(en altoDeVentana: CGFloat) -> CGFloat {
        let disponible = altoDeVentana - 2 * KurthChrome.overlayInset
        return min(disponible, max(360, altoDeVentana * 0.5))
    }

    /// Cuánto del tema va sobre el vidrio. El tema solo ya es casi opaco (0.75, KurthTheme.opacity)
    /// y taparía el vidrio; sin nada, el texto largo se pierde sobre una página movida.
    static let velo = 0.55

    var body: some View {
        GeometryReader { ventana in
        ZStack(alignment: enLaDerecha ? .bottomTrailing : .bottomLeading) {
            if !windowState.isSidebarAIChatVisible, hover.isOverlayVisible {
                KurthAgentChat(flotante: true)
                    .frame(width: windowState.aiSidebarWidth, height: Self.alto(en: ventana.size.height))
                    .environmentObject(browserManager)
                    .environment(windowState)
                    .environment(nookSettings)
                    .background { KurthHoverTheme(soloTema: true).opacity(Self.velo) }
                    .clipShape(KurthChrome.overlayShape)
                    .glassEffect(.regular, in: KurthChrome.overlayShape)
                    .nookElevation(.floating)
                    .alwaysArrowCursor(leavingFree: enLaDerecha ? .minXEdge : .maxXEdge, width: 14)
                    .overlay(alignment: enLaDerecha ? .leading : .trailing) {
                        AISidebarResizeView(kurthEnFlotante: true)
                            .frame(maxHeight: .infinity)
                            .environmentObject(browserManager)
                            .environment(windowState)
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
            if fijo { hover.isOverlayVisible = false }
        }
    }
}
