// Licensed under GPL-3.0. See LICENSE.
//
//  HoverSidebarManager.swift
//  Nook
//
//  Created by Jonathan Caudill on 2025-09-13.
//

import SwiftUI
import AppKit
import NookSettings
import NookWeb

/// Manages reveal/hide of the overlay sidebar when the real sidebar is collapsed.
/// Uses a global mouse-move monitor to handle edge hover, including slight overshoot
/// beyond the window's left boundary.
final class HoverSidebarManager: ObservableObject {
    // MARK: - Published State
    @Published var isOverlayVisible: Bool = false

    // MARK: - Configuration
    /// Width inside the window that triggers reveal when hovered.
    var triggerWidth: CGFloat = 6
    /// Horizontal slack to the left of the window to catch slight overshoot.
    var overshootSlack: CGFloat = 12
    /// Extra horizontal margin past the overlay to keep it open while interacting.
    var keepOpenHysteresis: CGFloat = 52
    /// Vertical slack to allow small overshoot above/below the window frame.
    var verticalSlack: CGFloat = 24
    // kurth: como Zen, ya abierta aguanta que el mouse salga de la ventana 200 pt de lado y
    // 100 arriba o abajo, y espera KurthMotion.hoverGrace antes de irse.
    var keepOpenOutsideSlack: CGFloat = 200
    var keepOpenVerticalSlack: CGFloat = 100
    private var pendingHide: DispatchWorkItem?

    /// Mostrar cancela cualquier ocultado pendiente.
    func reveal() {
        pendingHide?.cancel()
        pendingHide = nil
        if !isOverlayVisible { isOverlayVisible = true }
    }

    /// Ocultar espera la gracia; si el mouse vuelve antes, reveal() la cancela.
    func scheduleHide() {
        guard isOverlayVisible, pendingHide == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingHide = nil
            self?.isOverlayVisible = false
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + KurthMotion.hoverGrace, execute: work)
    }

    // MARK: - Dependencies
    weak var browserManager: BrowserManager?
    weak var windowRegistry: WindowRegistry?
    weak var nookSettings: NookSettingsService?

    // MARK: - Monitors
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isActive: Bool = false

    // MARK: - Lifecycle
    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
    }

    func start() {
        guard !isActive else { return }
        isActive = true

        // Local monitor for responsive updates while the app is active
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.scheduleHandleMouseMovement()
            return event
        }

        // Global monitor to detect near-edge hovers even when cursor overshoots beyond window bounds
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            self?.scheduleHandleMouseMovement()
        }
    }

    func stop() {
        isActive = false
        if let token = localMonitor { NSEvent.removeMonitor(token); localMonitor = nil }
        if let token = globalMonitor { NSEvent.removeMonitor(token); globalMonitor = nil }
        DispatchQueue.main.async { [weak self] in self?.isOverlayVisible = false }
    }

    deinit { stop() }

    // MARK: - Mouse Logic
    private func scheduleHandleMouseMovement() {
        // Ensure main-actor work since we touch NSApp/window and main-actor BrowserManager
        DispatchQueue.main.async { [weak self] in
            self?.handleMouseMovementOnMain()
        }
    }

    @MainActor
    private func handleMouseMovementOnMain() {
        guard browserManager != nil,
              let registry = windowRegistry,
              let activeState = registry.activeWindow else { return }

        // kurth: mientras se edita el tema, la barra se queda a la vista (se ve el tema aplicado).
        // Y sin pestañas también, como en Arc: de ahí sale lo siguiente (KurthEmptyPage.swift).
        let sinPestañas = browserManager?.tabs.selectedSession(in: activeState) == nil
        if KurthThemeStore.shared.editingSpaceID != nil || sinPestañas, !activeState.isSidebarVisible {
            reveal()
            return
        }

        // Never show overlay while the real sidebar is visible
        if activeState.isSidebarVisible {
            if isOverlayVisible {
                isOverlayVisible = false
            }
            return
        }

        guard let window = NSApp.keyWindow else {
            if isOverlayVisible {
                isOverlayVisible = false
            }
            return
        }

        // Mouse and window frames are in screen coordinates
        let mouse = NSEvent.mouseLocation
        let frame = window.frame

        // Allow slight vertical overshoot (kurth: más holgura si ya está abierta)
        let vSlack = isOverlayVisible ? keepOpenVerticalSlack : verticalSlack
        let verticalOK = mouse.y >= frame.minY - vSlack && mouse.y <= frame.maxY + vSlack
        if !verticalOK {
            scheduleHide()
            return
        }

        // Use saved width when sidebar is collapsed to size the overlay and sticky zone
        let overlayWidth = max(activeState.sidebarWidth, activeState.savedSidebarWidth)

        // Edge zone calculation
        var inTriggerZone = false
        var inKeepOpenZone = false
        var inSidebarContentZone = false

        // Right Side Calculations (if flag is true)
        if nookSettings?.sidebarPosition == .left {
            inTriggerZone = (mouse.x >= frame.minX - overshootSlack) && (mouse.x <= frame.minX + triggerWidth)
            // Keep-open zone: extends past the sidebar to allow moving cursor slightly into browser page
            inKeepOpenZone = (mouse.x >= frame.minX - keepOpenOutsideSlack) && (mouse.x <= frame.minX + overlayWidth + keepOpenHysteresis) // kurth
            // Sidebar content zone: cursor is actually over the sidebar itself
            inSidebarContentZone = (mouse.x >= frame.minX) && (mouse.x <= frame.minX + overlayWidth)
        } else {
            let rightEdge = frame.maxX
            inTriggerZone = (mouse.x >= rightEdge - triggerWidth - overshootSlack) && (mouse.x <= rightEdge + overshootSlack)
            // Keep-open zone: extends past the sidebar to allow moving cursor slightly into browser page
            inKeepOpenZone = (mouse.x >= rightEdge - overlayWidth - keepOpenHysteresis) && (mouse.x <= rightEdge + keepOpenOutsideSlack) // kurth
            // Sidebar content zone: cursor is actually over the sidebar itself
            inSidebarContentZone = (mouse.x >= rightEdge - overlayWidth) && (mouse.x <= rightEdge)
        }
        
        // Show sidebar if: in trigger zone, OR (sidebar visible AND (in keep-open zone OR over sidebar content))
        let shouldShow = inTriggerZone || (isOverlayVisible && (inKeepOpenZone || inSidebarContentZone))
        // kurth: la vista anima (resorte al entrar, curva al salir); aquí solo cambia el estado.
        if shouldShow { reveal() } else { scheduleHide() }
    }
}
