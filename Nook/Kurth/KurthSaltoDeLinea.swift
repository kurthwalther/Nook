// Licensed under GPL-3.0. See LICENSE.
//
//  KurthSaltoDeLinea.swift
//  Nook (rama kurth)
//
//  ⇧↩ (y ⌥↩) en la caja del agente meten un salto de línea en vez de mandar (Kurth, 27 sep: "si
//  presiono shift + enter no se va a segunda línea, solo se manda el mensaje").
//
//  El TextField vertical de SwiftUI manda con cualquier Enter, con o sin modificador, y
//  onKeyPress(.return) no llega siempre: el editor de campo (el NSTextView que AppKit pone encima
//  del campo mientras se escribe) se queda la tecla antes. Así que se atrapa el keyDown antes que
//  AppKit con un monitor local, y solo si quien está escribiendo es el editor que está encima de
//  esta caja: la barra de direcciones y los demás campos siguen igual.
//

import AppKit
import SwiftUI

struct KurthSaltoDeLinea: NSViewRepresentable {
    func makeNSView(context: Context) -> Vista { Vista() }
    func updateNSView(_ nsView: Vista, context: Context) {}

    final class Vista: NSView {
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] evento in
                let saltó = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let editor = self.editorQueSalta(evento) else { return false }
                    editor.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                return saltó ? nil : evento
            }
        }

        /// El editor de esta caja, si la tecla es ↩ (o el Enter del teclado numérico) con ⇧ o ⌥.
        private func editorQueSalta(_ evento: NSEvent) -> NSTextView? {
            guard evento.keyCode == 36 || evento.keyCode == 76 else { return nil }
            let teclas = evento.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard teclas.contains(.shift) || teclas.contains(.option),
                  !teclas.contains(.command), !teclas.contains(.control) else { return nil }
            guard let window, evento.window === window,
                  let editor = window.firstResponder as? NSTextView else { return nil }
            // Esta vista mide lo mismo que el campo: el editor que escribe en él cae encima.
            let caja = convert(bounds, to: nil)
            let suyo = editor.convert(editor.visibleRect, to: nil)
            return caja.intersects(suyo) ? editor : nil
        }
    }
}
