// Licensed under GPL-3.0. See LICENSE.
//
//  KurthThemePicker.swift
//  Nook (rama kurth)
//
//  Selector de tema como el de Zen (medidas de zen-gradient-generator.css y theme-picker.inc):
//  panel de 380 pt con padding 10 y radio 12; lienzo neutro con puntos de 1 px cada 6 px; hasta
//  3 colores (primario de 38 pt con borde blanco de 6, secundarios de 16 con borde de 3, escala
//  1.2 al arrastrar); ángulo = tono y distancia = luminosidad; armonías; 5 páginas de 8 presets;
//  onda de opacidad (0.30–0.80, háptica cada 0.1) y perilla de textura de 16 pasos con háptica.
//  La vista previa es en vivo; se guarda al cerrar.
//

import AppKit
import SwiftUI
import NookDesign
import NookSettings

struct KurthThemePicker: View {
    @Binding var theme: KurthTheme
    @Environment(\.nookSettings) private var nookSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var page = 0
    @State private var draggingIndex: Int?

    static let panelWidth: CGFloat = 380
    private let canvasSize: CGFloat = 360
    /// Movimientos que hace el selector solo (clic, presets): el spring de Zen (0.4 s, bounce 0.3).
    private let dotSpring = Animation.spring(duration: 0.4, bounce: 0.3)

    var body: some View {
        VStack(spacing: 10) {
            canvas
            presetsRow
            HStack(spacing: 14) {
                KurthOpacityWave(value: $theme.opacity)
                KurthTextureDial(value: $theme.grain)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
        .padding(10)
        .frame(width: Self.panelWidth)
    }

    // MARK: - Lienzo

    private var canvas: some View {
        ZStack {
            DotGrid(color: .primary.opacity(colorScheme == .dark ? 0.05 : 0.10))
            // Fondo que atrapa clic y arrastre en cualquier parte: mueve el primario (o lo crea).
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("kurthCanvas"))
                        .onChanged { value in
                            if value.translation == .zero { tapCanvas(at: value.location) }
                            else if !theme.dots.isEmpty { draggingIndex = 0; drag(index: 0, to: value.location) }
                        }
                        .onEnded { _ in draggingIndex = nil }
                )
            ForEach(Array(theme.dots.enumerated()), id: \.offset) { index, dot in
                dotView(index: index, dot: dot)
            }
            if theme.dots.isEmpty {
                Text("Haz clic para agregar un color")
                    .font(NookDesign.Font.secondary)
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: canvasSize, height: canvasSize)
        .coordinateSpace(.named("kurthCanvas"))
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topLeading) { schemeButtons.padding(8) }
        .overlay(alignment: .bottomTrailing) { colorActions.padding(8) }
    }

    private func dotView(index: Int, dot: KurthThemeDot) -> some View {
        let isPrimary = index == 0
        let size: CGFloat = isPrimary ? 38 : 16
        let border: CGFloat = isPrimary ? 6 : 3
        // El gesto va ANTES de .position: después, su área sería todo el lienzo y el último punto
        // se quedaba con todos los clics (se podía ajustar con 1 color y con 2–3 ya no).
        return Circle()
            .fill(Color(hex: dot.hex))
            .overlay(Circle().strokeBorder(.white, lineWidth: border))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .scaleEffect(draggingIndex == index ? 1.2 : 1)
            .animation(NookDesign.Motion.quick, value: draggingIndex)
            .contentShape(Circle().inset(by: -4))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("kurthCanvas"))
                    .onChanged { value in
                        draggingIndex = index
                        drag(index: index, to: value.location)
                    }
                    .onEnded { _ in draggingIndex = nil }
            )
            .contextMenu {
                if !isPrimary {
                    Button("Quitar este color") { removeDot() }
                }
            }
            .position(x: dot.x * canvasSize, y: dot.y * canvasSize)
    }

    // MARK: - Interacción

    private func normalized(_ point: CGPoint) -> (x: Double, y: Double) {
        // Sujeto al círculo inscrito.
        let x = point.x / canvasSize - 0.5, y = point.y / canvasSize - 0.5
        let d = sqrt(x * x + y * y), limit = 0.5
        let k = d > limit ? limit / d : 1
        return (0.5 + x * k, 0.5 + y * k)
    }

    private func tapCanvas(at point: CGPoint) {
        let p = normalized(point)
        withAnimation(dotSpring) {
            if theme.dots.isEmpty {
                theme.kind = .free
                theme.dots = [KurthThemeDot(hex: "#000000", x: p.x, y: p.y)]
                theme.harmony = "floating"
                theme.recolor()
            } else {
                theme.dots[0].x = p.x
                theme.dots[0].y = p.y
                theme.placeCompliments()
            }
        }
    }

    /// Arrastrar cualquier punto mueve toda la armonía: si es un secundario, el primario gira para
    /// que ese punto quede bajo el cursor.
    private func drag(index: Int, to location: CGPoint) {
        let p = normalized(location)
        if index == 0 {
            theme.dots[0].x = p.x
            theme.dots[0].y = p.y
        } else {
            let offsets = KurthThemeMath.angles(for: theme.harmony)
            let offset = index - 1 < offsets.count ? offsets[index - 1] * .pi / 180 : 0
            let dx = p.x - 0.5, dy = p.y - 0.5
            let distance = sqrt(dx * dx + dy * dy), angle = atan2(dy, dx) - offset
            theme.dots[0].x = 0.5 + distance * cos(angle)
            theme.dots[0].y = 0.5 + distance * sin(angle)
        }
        theme.placeCompliments()
    }

    private func addDot() {
        guard !theme.dots.isEmpty, theme.dots.count < 3 else { return }
        withAnimation(dotSpring) {
            theme.harmony = KurthThemeMath.defaultHarmony(dots: theme.dots.count + 1)
            theme.placeCompliments()
        }
    }

    private func removeDot() {
        guard !theme.dots.isEmpty else { return }
        withAnimation(dotSpring) {
            if theme.dots.count == 1 {
                theme.dots = []
                theme.harmony = "floating"
            } else {
                theme.harmony = KurthThemeMath.defaultHarmony(dots: theme.dots.count - 1)
                theme.placeCompliments()
            }
        }
    }

    private func cycleHarmony() {
        let options = KurthThemeMath.harmonies(forDots: theme.dots.count)
        guard options.count > 1, let i = options.firstIndex(of: theme.harmony) else { return }
        withAnimation(dotSpring) {
            theme.harmony = options[(i + 1) % options.count]
            theme.placeCompliments()
        }
    }

    private func apply(_ preset: KurthThemeMath.Preset) {
        withAnimation(dotSpring) {
            theme.kind = preset.kind
            theme.lightness = preset.lightness
            theme.harmony = preset.dots == 3 ? "analogous" : "floating"
            theme.dots = [KurthThemeDot(hex: preset.swatch[0], x: preset.position.x, y: preset.position.y)]
            theme.placeCompliments()
        }
    }

    // MARK: - Controles del lienzo

    private var schemeButtons: some View {
        HStack(spacing: 2) {
            schemeButton(.system, icon: "circle.lefthalf.filled", help: "Automático")
            schemeButton(.light, icon: "sun.max", help: "Claro")
            schemeButton(.dark, icon: "moon", help: "Oscuro")
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
    }

    private func schemeButton(_ mode: AppearanceMode, icon: String, help: String) -> some View {
        Button {
            nookSettings.appearanceMode = mode
        } label: {
            Image(systemName: icon)
                .font(NookDesign.Font.caption)
                .frame(width: 24, height: 22)
                .foregroundStyle(nookSettings.appearanceMode == mode ? .primary : .tertiary)
                .background(nookSettings.appearanceMode == mode ? Color.primary.opacity(0.1) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var colorActions: some View {
        HStack(spacing: 2) {
            actionButton("plus", help: "Agregar un color", enabled: !theme.dots.isEmpty && theme.dots.count < 3, action: addDot)
            actionButton("minus", help: "Quitar un color", enabled: !theme.dots.isEmpty, action: removeDot)
            actionButton("arrow.triangle.2.circlepath", help: "Cambiar armonía", enabled: KurthThemeMath.harmonies(forDots: theme.dots.count).count > 1, action: cycleHarmony)
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
    }

    private func actionButton(_ icon: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(NookDesign.Font.caption.weight(.semibold))
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .secondary : .quaternary)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: - Presets

    private var presetsRow: some View {
        HStack(spacing: 4) {
            pageButton("chevron.left", enabled: page > 0) { page -= 1 }
            HStack(spacing: 0) {
                ForEach(KurthThemeMath.presets[page]) { preset in
                    Button { apply(preset) } label: { PresetSwatch(colors: preset.swatch) }
                        .buttonStyle(PresetButtonStyle())
                        .frame(maxWidth: .infinity)
                }
            }
            .id(page)
            .transition(.opacity)
            pageButton("chevron.right", enabled: page < KurthThemeMath.presets.count - 1) { page += 1 }
        }
        .animation(NookDesign.Motion.quick, value: page)
        .frame(height: 34)
    }

    private func pageButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(NookDesign.Font.caption.weight(.semibold)).frame(width: 20, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .secondary : .quaternary)
        .disabled(!enabled)
    }
}

// MARK: - Piezas

private struct DotGrid: View {
    let color: Color
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 3
            while y < size.height {
                var x: CGFloat = 3
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(color))
                    x += 6
                }
                y += 6
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PresetSwatch: View {
    let colors: [String]
    var body: some View {
        Group {
            if colors.count == 1 {
                Circle().fill(Color(hex: colors[0]))
            } else {
                Circle().fill(LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .frame(width: 26, height: 26)
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

private struct PresetButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : (hovering ? 1.05 : 1))
            .animation(NookDesign.Motion.quick, value: configuration.isPressed)
            .animation(NookDesign.Motion.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Opacidad con onda

/// La línea se vuelve onda a medida que sube la opacidad; la perilla crece de 40×10 a 55×25.
struct KurthOpacityWave: View {
    @Binding var value: Double
    @State private var lastTenth = -1

    private var progress: Double {
        (value - KurthTheme.minOpacity) / (KurthTheme.maxOpacity - KurthTheme.minOpacity)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, mid = h / 2
            let knobW = 40 + 15 * progress, knobH = 10 + 15 * progress
            let knobX = knobW / 2 + (w - knobW) * progress
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    var path = Path()
                    let amplitude = (size.height / 2 - 4) * progress
                    let wavelength: CGFloat = 26
                    path.move(to: CGPoint(x: 4, y: mid))
                    var x: CGFloat = 4
                    while x <= size.width - 4 {
                        path.addLine(to: CGPoint(x: x, y: mid + sin(x / wavelength * 2 * .pi) * amplitude))
                        x += 1
                    }
                    context.stroke(path, with: .color(.primary.opacity(0.35)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                Capsule()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .frame(width: knobW, height: knobH)
                    .position(x: knobX, y: mid)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let p = min(max(drag.location.x / max(w, 1), 0), 1)
                value = KurthTheme.minOpacity + p * (KurthTheme.maxOpacity - KurthTheme.minOpacity)
                let tenth = Int((value * 10).rounded())
                if tenth != lastTenth {
                    if lastTenth >= 0 { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    lastTenth = tenth
                }
            })
        }
        .frame(height: 44)
        .help("Opacidad del tema")
    }
}

// MARK: - Textura en 16 pasos

/// Perilla circular: 16 puntos alrededor; al girar se ajusta al paso más cercano con háptica.
struct KurthTextureDial: View {
    @Binding var value: Double
    private let steps = 16

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height), r = size / 2 - 5
            let center = CGPoint(x: size / 2, y: size / 2)
            let angle = value * 2 * .pi - .pi / 2
            ZStack {
                ForEach(0..<steps, id: \.self) { i in
                    let a = Double(i) / Double(steps) * 2 * .pi - .pi / 2
                    Circle()
                        .fill(Color.primary.opacity(Double(i) / Double(steps) <= value && value > 0 ? 0.55 : 0.18))
                        .frame(width: 3, height: 3)
                        .position(x: center.x + r * cos(a), y: center.y + r * sin(a))
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .frame(width: 12, height: 12)
                    .position(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                var a = atan2(drag.location.y - center.y, drag.location.x - center.x) + .pi / 2
                if a < 0 { a += 2 * .pi }
                var snapped = (a / (2 * .pi) * Double(steps)).rounded() / Double(steps)
                if snapped >= 1 { snapped = 0 }
                if snapped != value {
                    value = snapped
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            })
        }
        .frame(width: 44, height: 44)
        .help("Textura")
    }
}
