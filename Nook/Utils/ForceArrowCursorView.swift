// Licensed under GPL-3.0. See LICENSE.
//
//  ForceArrowCursorView.swift
//  Nook
//
//  Created by Jonathan Caudill on 2025-09-15.
//

import AppKit
import SwiftUI

private final class ForceArrowCursorNSView: NSView {
    private var trackingArea: NSTrackingArea?
    // kurth: franjas de las orillas donde NO se fuerza la flecha, para que los redimensionadores
    // de los paneles flotantes pongan su cursor (SidebarHoverOverlayView, KurthAgentHoverOverlay).
    var freeEdges: [CGRectEdge] = []
    var freeWidth: CGFloat = 0

    private var arrowRect: NSRect {
        guard freeWidth > 0 else { return bounds }
        return freeEdges.reduce(bounds) { rect, edge in rect.divided(atDistance: freeWidth, from: edge).remainder }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let options: NSTrackingArea.Options = [
            .activeAlways,
            .mouseEnteredAndExited,
            .mouseMoved,
            .inVisibleRect
        ]
        trackingArea = NSTrackingArea(rect: arrowRect, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(arrowRect, cursor: .arrow)
        NSCursor.arrow.set()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // .inVisibleRect hace que el área de seguimiento sea toda la vista: la franja se revisa aquí.
        guard arrowRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        NSCursor.arrow.set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Do not change cursor here; let underlying views manage it.
    }
}

struct ForceArrowCursorView: NSViewRepresentable {
    var freeEdges: [CGRectEdge] = [] // kurth
    var freeWidth: CGFloat = 0 // kurth

    func makeNSView(context: Context) -> NSView {
        let v = ForceArrowCursorNSView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        v.freeEdges = freeEdges
        v.freeWidth = freeWidth
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? ForceArrowCursorNSView else { return }
        v.freeEdges = freeEdges
        v.freeWidth = freeWidth
        v.window?.invalidateCursorRects(for: v)
    }
}

extension View {
    /// Ensures the arrow cursor while hovering this view's visual bounds without affecting hit testing.
    func alwaysArrowCursor() -> some View {
        self.overlay(ForceArrowCursorView().allowsHitTesting(false))
    }

    /// kurth: igual, pero deja libre una franja de la orilla (para un redimensionador).
    func alwaysArrowCursor(leavingFree edge: CGRectEdge, width: CGFloat) -> some View {
        alwaysArrowCursor(leavingFree: [edge], width: width)
    }

    /// kurth: con varias orillas libres (la tarjeta del agente: la del ancho y la de arriba).
    func alwaysArrowCursor(leavingFree edges: [CGRectEdge], width: CGFloat) -> some View {
        self.overlay(ForceArrowCursorView(freeEdges: edges, freeWidth: width).allowsHitTesting(false))
    }
}
