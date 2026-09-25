// Licensed under GPL-3.0. See LICENSE.
//
//  KurthBarraInmersiva.swift
//  Nook (rama kurth)
//
//  Cuándo se muestra la barra en modo inmersivo (kurth.barAutoHide): al llevar el mouse a la orilla
//  de arriba de la ventana, y mientras siga sobre la barra. Una franja invisible de SwiftUI no
//  servía: esos primeros puntos son la zona de la barra de título de macOS, que se queda con el
//  mouse antes que la página (medido el 25 sep: la franja nunca recibía el hover). Es el mismo
//  método que la barra lateral que aparece con hover (HoverSidebarManager): monitores del
//  movimiento del mouse y su posición contra el marco de la ventana.
//

import AppKit
import Observation
import NookWeb

@MainActor
@Observable
final class KurthBarraInmersiva {
    private(set) var visible = false

    /// Alto de la barra: mientras el mouse esté dentro (con holgura), no se esconde.
    @ObservationIgnored var altoDeBarra: CGFloat = 44
    /// La ventana se busca en cada revisión: al aparecer la barra puede no estar asignada todavía.
    @ObservationIgnored private weak var estado: BrowserWindowState?
    @ObservationIgnored private var monitorLocal: Any?
    @ObservationIgnored private var monitorGlobal: Any?
    @ObservationIgnored private var ocultar: DispatchWorkItem?

    /// Cuántos puntos desde la orilla de arriba abren la barra, y cuánto puede pasarse el mouse
    /// por arriba de la ventana (al subirlo rápido se sale un poco).
    private let orilla: CGFloat = 6
    private let holguraArriba: CGFloat = 8

    func encender(en estado: BrowserWindowState) {
        self.estado = estado
        guard monitorLocal == nil else { return }
        let tipos: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        monitorLocal = NSEvent.addLocalMonitorForEvents(matching: tipos) { [weak self] evento in
            MainActor.assumeIsolated { self?.revisar() }
            return evento
        }
        monitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: tipos) { [weak self] _ in
            MainActor.assumeIsolated { self?.revisar() }
        }
    }

    func apagar() {
        if let monitorLocal { NSEvent.removeMonitor(monitorLocal) }
        if let monitorGlobal { NSEvent.removeMonitor(monitorGlobal) }
        monitorLocal = nil
        monitorGlobal = nil
        ocultar?.cancel()
        visible = false
    }

    private func revisar() {
        guard let ventana = estado?.windowHandle as? NSWindow, ventana.isVisible, ventana.isOnActiveSpace else { return }
        let mouse = NSEvent.mouseLocation
        let marco = ventana.frame
        let dentroDeAncho = mouse.x >= marco.minX && mouse.x <= marco.maxX
        // Puntos desde la orilla de arriba hacia abajo (negativo: arriba de la ventana).
        let desdeArriba = marco.maxY - mouse.y
        let enLaOrilla = dentroDeAncho && desdeArriba >= -holguraArriba && desdeArriba <= orilla
        let sobreLaBarra = dentroDeAncho && desdeArriba >= -holguraArriba && desdeArriba <= altoDeBarra + 10
        if enLaOrilla || (visible && sobreLaBarra) {
            ocultar?.cancel()
            if !visible { visible = true }
        } else if visible, ocultar == nil || ocultar?.isCancelled == true {
            let tarea = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.visible = false
                    self?.ocultar = nil
                }
            }
            ocultar = tarea
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: tarea)
        }
    }
}
