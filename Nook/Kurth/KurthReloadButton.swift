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
//  El indicador es el "comet" de loading.dev (MIT, Jakub Krehel), portado a SwiftUI: Kurth lo
//  eligió el 25 sep entre arc, comet, ring, snake y la rueda clásica de macOS, que se probaron
//  en vivo desde el clic derecho de la barra y luego se quitaron.
//

import SwiftUI
import NookDesign
import NookUI
import NookWeb

struct KurthReloadButton: View {
    let session: PageSession?
    @State private var alPasar = false

    private var cargando: Bool { session?.isLoading == true }

    var body: some View {
        Button {
            if session?.isLoading == true { session?.stop() } else { session?.refresh() }
        } label: {
            Label {
                Text(cargando ? "Detener" : "Recargar")
            } icon: {
                if cargando && !alPasar {
                    KurthLoadingIndicator()
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

/// El cometa de loading.dev, en el gris de los íconos de la barra. Allá se dibuja a 20 px con
/// grosor 0.12 del lado y giro lineal de 700 ms; aquí va a 12 pt con las mismas proporciones. Un
/// loader de CSS no entra tal cual en un botón nativo: se reconstruye con TimelineView (un reloj
/// que redibuja la vista en cada cuadro).
struct KurthLoadingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lado: CGFloat = 12
    private let ms: Double = 700

    var body: some View {
        // Cola: anillo con degradado angular de transparente a lleno (el degradado va en la máscara
        // para que el color sea el del ícono); cabeza: un punto del grosor del anillo, arriba, donde
        // el degradado llega a lleno. Con "reducir movimiento", quieto.
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate * 1000
            let fase = reduceMotion ? 0.3 : t.truncatingRemainder(dividingBy: ms) / ms
            let grosor = lado * 0.12
            ZStack {
                Circle()
                    .strokeBorder(lineWidth: grosor)
                    .mask(AngularGradient(colors: [.clear, .black], center: .center,
                                          startAngle: .degrees(-90), endAngle: .degrees(270)))
                Circle()
                    .frame(width: grosor, height: grosor)
                    .offset(y: -(lado - grosor) / 2)
            }
            .frame(width: lado, height: lado)
            .rotationEffect(.degrees(fase * 360))
        }
    }
}
