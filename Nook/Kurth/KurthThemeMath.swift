// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
//  KurthThemeMath.swift
//  Nook (rama kurth)
//
//  Traducción a Swift de partes de zen-browser/desktop (commit 7dfcd34):
//  src/zen/spaces/ZenGradientGenerator.mjs (hslToRgb, rgbToHsl, getColorFromPosition,
//  colorHarmonies, calculateCompliments, blendWithWhiteOverlay) y los presets de
//  src/browser/base/content/zen-panels/theme-picker.inc. Por eso este archivo va bajo MPL-2.0
//  (§3.1) y convive con el resto de Nook en GPL-3.0 (§3.3).
//

import AppKit
import SwiftUI

enum KurthThemeMath {

    // MARK: - HSL ↔ RGB (0…1)

    static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (hue(h + 1.0 / 3), hue(h), hue(h - 1.0 / 3))
    }

    static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d != 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
        }
        h *= 60
        if h < 0 { h += 360 }
        let l = (mx + mn) / 2
        let s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        return (h, s, l)
    }

    // MARK: - Hex

    static func rgb(fromHex hex: String) -> (Double, Double, Double) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count >= 6, let v = UInt64(s.prefix(6), radix: 16) else { return (0.5, 0.5, 0.5) }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        func c(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    // MARK: - Posición en el lienzo → color (getColorFromPosition)

    /// Cómo traduce la distancia al centro. Libre: centro negro, orilla clara (luminosidad =
    /// distancia). Con luminosidad fija (presets): distancia = saturación. Grises: sin saturación.
    enum Kind: String, Codable { case free, lightness, gray }

    /// x, y en 0…1 dentro del lienzo; el círculo útil tiene radio 0.5 alrededor de (0.5, 0.5).
    static func color(x: Double, y: Double, kind: Kind, lightness: Double) -> String {
        let dx = x - 0.5, dy = y - 0.5
        let distance = min(sqrt(dx * dx + dy * dy) / 0.5, 1)   // 0 centro, 1 orilla
        var angle = atan2(dy, dx) * 180 / .pi
        if angle < 0 { angle += 360 }
        let h = angle / 360
        let (s, l): (Double, Double)
        switch kind {
        case .free: (s, l) = ((90 + distance * 10) / 100, distance)
        case .lightness: (s, l) = (1 - distance, lightness)
        case .gray: (s, l) = (0, distance)
        }
        let (r, g, b) = hslToRGB(h: h, s: s, l: l)
        return hex(r, g, b)
    }

    /// Dónde cae un color en el lienzo libre: ángulo = tono, distancia = luminosidad.
    static func position(forHex hex: String) -> (x: Double, y: Double) {
        let (r, g, b) = rgb(fromHex: hex)
        let hsl = rgbToHSL(r, g, b)
        let a = hsl.h * .pi / 180, d = min(max(hsl.l, 0.08), 1) * 0.5
        return (0.5 + d * cos(a), 0.5 + d * sin(a))
    }

    // MARK: - Armonías (colorHarmonies)

    static let harmonies: [(type: String, angles: [Double])] = [
        ("complementary", [180]),
        ("singleAnalogous", [310]),
        ("splitComplementary", [150, 210]),
        ("analogous", [50, 310]),
        ("triadic", [120, 240]),
        ("floating", []),
    ]

    static func angles(for harmony: String) -> [Double] {
        harmonies.first { $0.type == harmony }?.angles ?? []
    }

    /// La armonía por defecto para N puntos (N−1 ángulos).
    static func defaultHarmony(dots: Int) -> String {
        switch dots {
        case 2: return "complementary"
        case 3: return "analogous"
        default: return "floating"
        }
    }

    /// Las armonías que sirven para N puntos, para ciclarlas con el botón.
    static func harmonies(forDots dots: Int) -> [String] {
        harmonies.filter { $0.angles.count == dots - 1 }.map(\.type)
    }

    /// Posiciones de los secundarios: misma distancia que el primario, girados por la armonía.
    static func compliments(primary: (x: Double, y: Double), harmony: String) -> [(x: Double, y: Double)] {
        let dx = primary.x - 0.5, dy = primary.y - 0.5
        let distance = min(sqrt(dx * dx + dy * dy), 0.5)
        let base = atan2(dy, dx)
        return angles(for: harmony).map { offset in
            let a = base + offset * .pi / 180
            return (0.5 + distance * cos(a), 0.5 + distance * sin(a))
        }
    }

    // MARK: - Color que se pinta (blendWithWhiteOverlay en macOS)

    /// Cada color del tema se mezcla con blanco y lleva de alfa `opacity` (KurthThemeBackground
    /// usa una fija, tintStrength; la opacidad del tema es la de toda la superficie). Con
    /// opacidad 0.5 queda 92 % color + 8 % blanco.
    static func paintColor(hex: String, opacity: Double) -> Color {
        let (r, g, b) = rgb(fromHex: hex)
        let mix = min(1, opacity + 0.30 + 0.6 * (1 - (opacity + 0.30)))
        return Color(.sRGB,
                     red: r * mix + (1 - mix),
                     green: g * mix + (1 - mix),
                     blue: b * mix + (1 - mix),
                     opacity: opacity)
    }

    // MARK: - Presets (theme-picker.inc): 5 páginas de 8

    struct Preset: Identifiable {
        let id: Int
        let kind: Kind
        let lightness: Double
        let dots: Int
        /// Posición del primario en el lienzo de Zen (360 × 360, centro en 180,180).
        let position: (x: Double, y: Double)
        /// Colores de la muestra redonda.
        let swatch: [String]
    }

    static let presets: [[Preset]] = {
        func p(_ id: Int, _ kind: Kind, _ l: Double, _ dots: Int, _ x: Double, _ y: Double, _ swatch: [String]) -> Preset {
            Preset(id: id, kind: kind, lightness: l / 100, dots: dots, position: (x / 360, y / 360), swatch: swatch)
        }
        return [
            [p(0, .lightness, 90, 1, 240, 240, ["#f4efdf"]), p(1, .lightness, 80, 1, 233, 157, ["#f0b8cd"]),
             p(2, .lightness, 80, 1, 236, 111, ["#e9c3e3"]), p(3, .lightness, 70, 1, 234, 173, ["#da7682"]),
             p(4, .lightness, 70, 1, 220, 187, ["#eb8570"]), p(5, .lightness, 60, 1, 225, 237, ["#dcce7f"]),
             p(6, .lightness, 60, 1, 147, 195, ["#5becad"]), p(7, .lightness, 50, 1, 81, 84, ["#919bb5"])],
            [p(8, .lightness, 90, 3, 240, 240, ["#F5EDD6", "#DDF3D8", "#F3D8E1"]), p(9, .lightness, 85, 3, 233, 157, ["#F3BEDE", "#F7DEBA", "#DFC3EE"]),
             p(10, .lightness, 80, 3, 236, 111, ["#E5B3E4", "#ECACB2", "#C5B9DF"]), p(11, .lightness, 70, 3, 234, 173, ["#EB7A9F", "#EFEF76", "#D285E0"]),
             p(12, .lightness, 70, 3, 220, 187, ["#F2737B", "#AFF273", "#E67DE8"]), p(13, .lightness, 60, 3, 225, 237, ["#DDCD55", "#61D45E", "#D75B7C"]),
             p(14, .lightness, 60, 3, 147, 195, ["#4BE7D2", "#54AFDE", "#3EF470"]), p(15, .lightness, 55, 3, 81, 84, ["#7A849E", "#8975A4", "#74A2A4"])],
            [p(16, .lightness, 10, 1, 171, 72, ["#5D566A"]), p(17, .lightness, 40, 1, 265, 79, ["#997096"]),
             p(18, .lightness, 35, 1, 301, 176, ["#956066"]), p(19, .lightness, 30, 1, 237, 210, ["#9c6645"]),
             p(20, .lightness, 30, 1, 91, 228, ["#517b6c"]), p(21, .lightness, 25, 1, 67, 159, ["#576e75"]),
             p(22, .lightness, 20, 1, 314, 235, ["#836D5F"]), p(23, .lightness, 20, 1, 118, 215, ["#447464"])],
            [p(24, .lightness, 10, 3, 171, 72, ["#171122", "#250E23", "#121621"]), p(25, .lightness, 40, 3, 265, 79, ["#804C7C", "#8D3F42", "#615874"]),
             p(26, .lightness, 35, 3, 301, 176, ["#7A3840", "#7E7934", "#6F446E"]), p(27, .lightness, 30, 3, 237, 210, ["#834116", "#408019", "#7A1F5B"]),
             p(28, .lightness, 30, 3, 91, 228, ["#2D6C55", "#345565", "#347623"]), p(29, .lightness, 25, 3, 67, 159, ["#2D4A53", "#2E3251", "#265A41"]),
             p(30, .lightness, 20, 3, 314, 235, ["#402F26", "#374026", "#3B2B34"]), p(31, .lightness, 20, 3, 118, 215, ["#16503D", "#1A3C4C", "#1B570F"])],
            // Grises: Zen empieza en #E0E0E0; aquí el primero es blanco (orilla del lienzo) y sale
            // #202020, que casi no se distingue del negro. Kurth pidió blanco el 23 sep.
            [p(32, .gray, 0, 1, 360, 180, ["#FFFFFF"]), p(33, .gray, 0, 1, 340, 180, ["#E0E0E0"]),
             p(34, .gray, 0, 1, 315, 180, ["#C0C0C0"]), p(35, .gray, 0, 1, 292.5, 180, ["#A0A0A0"]),
             p(36, .gray, 0, 1, 270, 180, ["#808080"]), p(37, .gray, 0, 1, 247.5, 180, ["#606060"]),
             p(38, .gray, 0, 1, 225, 180, ["#404040"]), p(39, .gray, 0, 1, 180, 180, ["#000000"])],
        ]
    }()
}
