// Licensed under GPL-3.0. See LICENSE.
//
//  KurthReloadButton.swift
//  Nook (rama kurth)
//
//  Recargar / cargando / detener. Mientras la página carga se ve un indicador, no la X; la X
//  (detener) solo aparece al pasar el mouse por encima (Kurth, 25 sep: "debería ser un icono de
//  cargando, y si te pones arriba, la X"). Lo comparten la barra (KurthTopBarView, en las dos
//  variantes) y la tira compacta (KurthTabStrip); cada sitio le pone su estilo de ícono.
//
//  El indicador tiene cuatro variantes (`kurth.loadingStyle`, clic derecho en la barra), para
//  elegir viendo. `kurth.loadingDemo` deja el botón en estado de carga para compararlas sin
//  esperar a que cargue una página.
//

import SwiftUI
import NookDesign
import NookUI
import NookWeb

struct KurthReloadButton: View {
    let session: PageSession?
    @State private var alPasar = false
    @AppStorage("kurth.loadingStyle") private var estilo = "dots"
    @AppStorage("kurth.loadingDemo") private var demo = false

    private var cargando: Bool { session?.isLoading == true || demo }

    var body: some View {
        Button {
            if session?.isLoading == true { session?.stop() } else { session?.refresh() }
        } label: {
            Label {
                Text(cargando ? "Detener" : "Recargar")
            } icon: {
                if cargando && !alPasar {
                    KurthLoadingIndicator(estilo: estilo)
                        .transition(.opacity)
                } else {
                    Image(systemName: cargando ? "xmark" : "arrow.clockwise")
                        .transition(.opacity)
                }
            }
        }
        .onHoverTracking { alPasar = $0 }
        .animation(NookDesign.Motion.quick, value: alPasar)
        .animation(NookDesign.Motion.quick, value: cargando)
        .help(cargando ? "Detener" : "Recargar")
    }
}

/// Las variantes del indicador, todas en el gris de los íconos de la barra y de 11 a 14 pt.
/// Un loader de CSS o de Lottie no entra tal cual en un botón nativo, pero casi todos son formas
/// simples animadas: se reconstruyen aquí con TimelineView (un reloj que redibuja la vista en
/// cada cuadro) o con los efectos de SF Symbols.
struct KurthLoadingIndicator: View {
    let estilo: String
    @State private var giro = false

    static let estilos: [(clave: String, nombre: String)] = [
        ("dots", "Puntos (símbolo de progreso)"),
        ("claude", "Flor de Claude (como este chat)"),
        ("rays", "Rayos (rueda, versión SF)"),
        ("dotted", "Anillo de puntos"),
        ("spinner", "Rueda clásica de macOS"),
        ("rotate", "La flecha girando"),
        ("ring", "Arco fino"),
        ("bounce", "Tres puntos que brincan"),
        ("bars", "Tres barras"),
    ]

    /// Los cuadros del spinner de Claude Code: la flor crece y se cierra. El asterisco de ocho
    /// puntas lleva el selector de presentación de texto para que no salga como emoji.
    private static let flor = ["·", "✢", "✳\u{FE0E}", "✶", "✻", "✽", "✻", "✶", "✳\u{FE0E}", "✢"]

    var body: some View {
        switch estilo {
        case "claude":
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                let i = Int(ctx.date.timeIntervalSinceReferenceDate * 10) % Self.flor.count
                Text(Self.flor[i])
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 14, height: 14)
            }
        case "rays":
            Image(systemName: "rays")
                .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, isActive: true)
        case "dotted":
            Image(systemName: "circle.dotted")
                .symbolEffect(.variableColor.cumulative.dimInactiveLayers.nonReversing, isActive: true)
        case "spinner":
            // El NSProgressIndicator de siempre: la rueda de rayos que se apagan.
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.75)
        case "rotate":
            // La misma flecha de recargar, dando vueltas: "está recargando".
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(giro ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: giro)
                .onAppear { giro = true }
        case "ring":
            // Un arco de tres cuartos que gira, con el mismo grosor que los trazos de los íconos.
            Circle()
                .trim(from: 0.2, to: 1)
                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 11, height: 11)
                .rotationEffect(.degrees(giro ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: giro)
                .onAppear { giro = true }
        case "bounce":
            // Tres puntos que brincan por turnos, como el "escribiendo…" de Mensajes.
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .frame(width: 3, height: 3)
                            .offset(y: -max(0, sin(t * 7 - Double(i) * 1.1)) * 3)
                    }
                }
                .frame(width: 14, height: 12)
            }
        case "bars":
            // Tres barras que suben y bajan desfasadas, como un ecualizador chico.
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .frame(width: 2.5, height: 5 + 7 * (0.5 + 0.5 * sin(t * 7 - Double(i) * 1.1)))
                    }
                }
                .frame(width: 14, height: 12)
            }
        default:
            // El símbolo de progreso de SF con su efecto de color por capas.
            Image(systemName: "progress.indicator")
                .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, isActive: true)
        }
    }
}
