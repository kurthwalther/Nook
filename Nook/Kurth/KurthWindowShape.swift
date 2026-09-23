// Licensed under GPL-3.0. See LICENSE.
//
//  KurthWindowShape.swift
//  Nook (rama kurth)
//
//  Radios concéntricos (la regla de Apple): para que ConcentricRectangle calcule "esquina de la
//  ventana − separación", SwiftUI necesita saber cuál es la forma del contenedor. En Nook nadie
//  se la daba y todas caían a su mínimo. Aquí se lee la esquina REAL de la ventana (16 pt en
//  macOS 27, leído con effectiveCornerRadii el 23 sep) y se declara como forma del contenedor.
//  Ojo al medir en capturas: las esquinas son curvas continuas (squircle), no círculos; ajustarles
//  un círculo infla el radio ~1 pt (medí 17.1 para una ventana de 16).
//
//  Lectura: macOS 27 trae NSView.cornerConfiguration. Una vista pegada a la orilla que pide
//  esquinas concéntricas con su contenedor (mínimo 0) recibe en effectiveCornerRadii el radio
//  de la ventana. En macOS 26 no existe; ahí se queda en 16, el valor de Tahoe.
//

import AppKit
import SwiftUI

struct KurthWindowShape: ViewModifier {
    @State private var radius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(KurthWindowCornerReader { radius = $0 }.allowsHitTesting(false))
            .containerShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func kurthWindowShape() -> some View { modifier(KurthWindowShape()) }
}

private struct KurthWindowCornerReader: NSViewRepresentable {
    let onRadius: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onRadius = onRadius
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onRadius = onRadius
    }

    final class ReaderView: NSView {
        var onRadius: ((CGFloat) -> Void)?
        private var lastReported: CGFloat = 0

        @available(macOS 27.0, *)
        override var cornerConfiguration: NSViewCornerConfiguration? {
            .uniformCorners(radius: .containerConcentric(0))
        }

        @available(macOS 27.0, *)
        override func viewDidChangeEffectiveCornerRadii() {
            super.viewDidChangeEffectiveCornerRadii()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if #available(macOS 27.0, *) { invalidateCornerConfiguration() }
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        private func report() {
            guard #available(macOS 27.0, *), let radii = effectiveCornerRadii else { return }
            let radius = max(radii.topLeft, radii.topRight, radii.bottomLeft, radii.bottomRight)
            guard radius > 0, abs(radius - lastReported) > 0.25 else { return }
            lastReported = radius
            DispatchQueue.main.async { [onRadius] in onRadius?(radius) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
