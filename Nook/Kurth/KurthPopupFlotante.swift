// Licensed under GPL-3.0. See LICENSE.
//
//  KurthPopupFlotante.swift
//  Nook (rama kurth)
//
//  Una lista que sale como pop-up de verdad: una ventana hija sin borde, encima de la vista que la
//  ancla, con el material y la sombra de los menús de macOS (Kurth, 26 sep: la lista de «/» y «@»
//  salía sobre el bloque blanco de la caja y se veía poco).
//
//  Por qué una ventana y no un .popover de SwiftUI: el popover toma el foco del teclado y el campo
//  de texto deja de recibir lo que se escribe; aquí la ventana no se vuelve key, así que ↑/↓, Enter
//  y lo que se sigue escribiendo siguen yendo al campo. Por qué no una capa (overlay): una capa no
//  puede salirse del panel del agente, y ahí la recortaba la máscara del chat.
//

import AppKit
import SwiftUI

/// Se pone como `.background` de la vista ancla: mide su marco y muestra `contenido` en una ventana
/// hija justo encima, del mismo ancho.
struct KurthPopupFlotante<Contenido: View>: NSViewRepresentable {
    let visible: Bool
    /// Separación entre la orilla de arriba del ancla y el pop-up.
    var separacion: CGFloat = 6
    @ViewBuilder let contenido: () -> Contenido

    func makeNSView(context: Context) -> KurthAnclaDePopup {
        KurthAnclaDePopup()
    }

    func updateNSView(_ vista: KurthAnclaDePopup, context: Context) {
        vista.separacion = separacion
        vista.actualizar(visible: visible, contenido: AnyView(contenido()))
    }

    static func dismantleNSView(_ vista: KurthAnclaDePopup, coordinator: ()) {
        vista.cerrar()
    }
}

/// Panel que nunca se vuelve key: el foco del teclado se queda en la ventana del navegador.
private final class KurthPanelDePopup: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class KurthAnclaDePopup: NSView {
    var separacion: CGFloat = 6
    private var panel: KurthPanelDePopup?
    private var hosting: NSHostingView<AnyView>?

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // el ancla no se queda clics

    func actualizar(visible: Bool, contenido: AnyView) {
        guard visible, window != nil else { cerrar(); return }
        let ancho = max(bounds.width, 120)
        let vista = AnyView(contenido.frame(width: ancho))
        if let hosting {
            hosting.rootView = vista
        } else {
            crear(con: vista)
        }
        colocar()
    }

    private func crear(con vista: AnyView) {
        let hosting = NSHostingView(rootView: vista)
        hosting.sizingOptions = [.intrinsicContentSize]
        let panel = KurthPanelDePopup(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true // la sombra del sistema sigue la forma redonda del contenido
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = window?.effectiveAppearance
        panel.contentView = hosting
        panel.alphaValue = 0
        self.hosting = hosting
        self.panel = panel
        window?.addChildWindow(panel, ordered: .above)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func colocar() {
        guard let window, let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let tamaño = hosting.fittingSize
        let marco = window.convertToScreen(convert(bounds, to: nil))
        panel.setFrame(NSRect(x: marco.minX, y: marco.maxY + separacion,
                              width: tamaño.width, height: tamaño.height), display: true)
        panel.invalidateShadow()
    }

    override func layout() {
        super.layout()
        colocar()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cerrar() }
    }

    func cerrar() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        hosting = nil
    }
}
