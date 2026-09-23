// Licensed under GPL-3.0. See LICENSE.
//
//  KurthBackdropBlur.swift
//  Nook (rama kurth)
//
//  Desenfoque puro de lo que pasa por detrás, sin el tinte blanco o gris que todos los
//  materiales de macOS le agregan. Es la misma capa que usan los materiales por dentro
//  (CABackdropLayer) con solo el filtro de blur y un poco de saturación, como en iOS.
//  Si macOS dejara de tener esas clases, la vista queda vacía y no rompe nada.
//

import AppKit
import QuartzCore
import SwiftUI

struct KurthBackdropBlur: NSViewRepresentable {
    var radius: CGFloat
    var saturation: CGFloat
    /// Puntos al fondo en los que el blur se apaga, en vez de cortar con una línea.
    var fade: CGFloat

    func makeNSView(context: Context) -> BlurView { BlurView() }

    func updateNSView(_ view: BlurView, context: Context) {
        view.configure(radius: radius, saturation: saturation, fade: fade)
    }

    final class BlurView: NSView {
        private let backdrop: CALayer? = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init()
        private let fadeMask = CAGradientLayer()
        private var fade: CGFloat = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            guard let backdrop else { return }
            layer?.addSublayer(backdrop)
            fadeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            layer?.mask = fadeMask
        }

        required init?(coder: NSCoder) { nil }

        func configure(radius: CGFloat, saturation: CGFloat, fade: CGFloat) {
            self.fade = fade
            guard let backdrop, let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return }
            let make = NSSelectorFromString("filterWithType:")
            guard filterClass.responds(to: make) else { return }
            var filters: [NSObject] = []
            if let blur = filterClass.perform(make, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject {
                blur.setValue(radius, forKey: "inputRadius")
                blur.setValue(true, forKey: "inputNormalizeEdges")
                filters.append(blur)
            }
            if saturation != 1,
               let saturate = filterClass.perform(make, with: "colorSaturate")?.takeUnretainedValue() as? NSObject {
                saturate.setValue(saturation, forKey: "inputAmount")
                filters.append(saturate)
            }
            backdrop.filters = filters
            needsLayout = true
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdrop?.frame = bounds
            fadeMask.frame = bounds
            // La capa no es "flipped": y = 0 es abajo. Opaco arriba, se apaga en los últimos `fade` pt.
            let solidUntil = bounds.height > 0 ? Float(min(1, fade / bounds.height)) : 0
            fadeMask.startPoint = CGPoint(x: 0.5, y: 1)
            fadeMask.endPoint = CGPoint(x: 0.5, y: 0)
            fadeMask.locations = [0, NSNumber(value: 1 - solidUntil), 1]
            CATransaction.commit()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
