// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
//  KurthThemeBackground.swift
//  Nook (rama kurth)
//
//  Fondo de ventana con el tema del Space. La receta del tinte es la de getGradient en
//  zen-browser/desktop src/zen/spaces/ZenGradientGenerator.mjs (commit 7dfcd34):
//   - 0 colores: nada en claro, negro .4 en oscuro.
//   - 1 color: plano, sin degradado.
//   - 2 colores: lineal de 150° con el primario (sólido a 30 %, transparente a 120 %) sobre un
//     lineal de −30° igual con el segundo.
//   - 3 colores: radial en (0,0) con el primario (10 → 70 %), radial en (95 %,0) con el segundo
//     (0 → 75 %) y lineal de −5° con el tercero (10 → 80 %).
//  Las capas se combinan con `lighten` (zen-browser-ui.css:64,76): por canal gana el más claro,
//  y por eso los cruces no salen lodosos. Va sobre un material translúcido (KurthWindowTheme),
//  así que el alfa del tinte es la transparencia real de la ventana.
//

import SwiftUI
import NookDesign
import NookWeb

struct KurthThemeBackground: View {
    let theme: KurthTheme
    var isActive = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                tint(size: geo.size)
                    .compositingGroup()
                    // Ventana inactiva: el tinte se apaga un poco, como el material de Zen.
                    .opacity(isActive ? 1 : 0.6)
                if theme.grain > 0 {
                    Image("noise_texture")
                        .resizable(resizingMode: .tile)
                        .blendMode(.overlay)
                        .opacity(0.45 * theme.grain)
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func tint(size: CGSize) -> some View {
        let colors = theme.dots.map { KurthThemeMath.paintColor(hex: $0.hex, opacity: theme.opacity) }
        switch colors.count {
        case 0:
            colorScheme == .dark ? Color.black.opacity(0.4) : Color.clear
        case 1:
            colors[0]
        case 2:
            ZStack {
                Self.linear(angle: -30, color: colors[1], from: 0.30, to: 1.20, size: size)
                Self.linear(angle: 150, color: colors[0], from: 0.30, to: 1.20, size: size)
                    .blendMode(.lighten)
            }
        default:
            ZStack {
                Self.radial(at: UnitPoint(x: 0, y: 0), color: colors[0], from: 0.10, to: 0.70, size: size)
                Self.radial(at: UnitPoint(x: 0.95, y: 0), color: colors[1], from: 0, to: 0.75, size: size)
                    .blendMode(.lighten)
                Self.linear(angle: -5, color: colors[2], from: 0.10, to: 0.80, size: size)
                    .blendMode(.lighten)
            }
        }
    }

    // MARK: - Degradados de CSS en SwiftUI

    /// `linear-gradient(<angle>deg, color from, transparent to)`. En CSS 0° apunta arriba y el
    /// ángulo gira en sentido horario; la línea mide |w·sen θ| + |h·cos θ|. Si `to` pasa del
    /// 100 %, el alfa en el 100 % se interpola (lo que CSS dibujaría en el borde).
    static func linear(angle: Double, color: Color, from: Double, to: Double, size: CGSize) -> LinearGradient {
        let t = angle * .pi / 180
        let dir = CGVector(dx: sin(t), dy: -cos(t))
        let w = max(size.width, 1), h = max(size.height, 1)
        let length = abs(w * sin(t)) + abs(h * cos(t))
        let start = UnitPoint(x: (w / 2 - dir.dx * length / 2) / w, y: (h / 2 - dir.dy * length / 2) / h)
        let end = UnitPoint(x: (w / 2 + dir.dx * length / 2) / w, y: (h / 2 + dir.dy * length / 2) / h)
        return LinearGradient(stops: stops(color: color, from: from, to: to), startPoint: start, endPoint: end)
    }

    /// `radial-gradient(circle at X Y, color from, transparent to)`, con el círculo hasta la
    /// esquina más lejana (el tamaño por defecto de CSS).
    static func radial(at center: UnitPoint, color: Color, from: Double, to: Double, size: CGSize) -> RadialGradient {
        let cx = center.x * size.width, cy = center.y * size.height
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
        let radius = corners.map { hypot($0.x - cx, $0.y - cy) }.max() ?? 1
        return RadialGradient(stops: stops(color: color, from: from, to: to), center: center, startRadius: 0, endRadius: radius)
    }

    /// Paradas de color → transparente. Siempre `color.opacity(…)`, nunca `Color.clear`: al
    /// interpolar hacia un transparente negro sale un halo gris.
    private static func stops(color: Color, from: Double, to: Double) -> [Gradient.Stop] {
        if to <= 1 {
            return [.init(color: color, location: 0), .init(color: color, location: from),
                    .init(color: color.opacity(0), location: to), .init(color: color.opacity(0), location: 1)]
        }
        let atEdge = max(0, 1 - (1 - from) / (to - from))
        return [.init(color: color, location: 0), .init(color: color, location: from),
                .init(color: color.opacity(atEdge), location: 1)]
    }
}
