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
//  El indicador tiene cinco variantes (`kurth.loadingStyle`, clic derecho en la barra): cuatro
//  portadas de loading.dev (MIT, Jakub Krehel), las que Kurth eligió el 25 sep, y la rueda
//  clásica de macOS. `kurth.loadingDemo` deja el botón en estado de carga para compararlas sin
//  esperar a que cargue una página.
//

import SwiftUI
import NookDesign
import NookUI
import NookWeb

struct KurthReloadButton: View {
    let session: PageSession?
    @State private var alPasar = false
    @AppStorage("kurth.loadingStyle") private var estilo = "arc"
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

/// Los indicadores, en el gris de los íconos de la barra. Los de loading.dev se dibujan a 20 px
/// con un círculo de radio 10 en un lienzo de 24 y trazo 2.5, puntas redondas y giro lineal; aquí
/// van a 12 pt con las mismas proporciones, tiempos y curvas. Un loader de CSS no entra tal cual en
/// un botón nativo: se reconstruye con TimelineView (un reloj que redibuja la vista en cada cuadro).
struct KurthLoadingIndicator: View {
    let estilo: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let estilos: [(clave: String, nombre: String)] = [
        ("arc", "Arco"),
        ("comet", "Cometa"),
        ("ring", "Anillo"),
        ("snake", "Serpiente"),
        ("spinner", "Rueda clásica de macOS"),
    ]

    /// Lado del indicador; el círculo de loading.dev ocupa 20 de 24 y el trazo 2.5 de 24.
    private let lado: CGFloat = 12
    private var diametro: CGFloat { lado * 20 / 24 }
    private var trazo: CGFloat { lado * 2.5 / 24 }
    /// Perímetro del círculo de radio 10, en unidades del lienzo (62.83): ahí se miden los guiones.
    private let perimetro = 2 * Double.pi * 10

    var body: some View {
        switch estilo {
        case "spinner":
            // El NSProgressIndicator de siempre: la rueda de rayos que se apagan.
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.75)
        case "comet":
            // Cola: anillo con degradado angular de transparente a lleno (el degradado va en la
            // máscara para que el color sea el del ícono); cabeza: un punto del grosor del anillo,
            // arriba, donde el degradado llega a lleno. Grosor 0.12 del lado, 700 ms.
            reloj(700) { fase in
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
        case "ring":
            // Pista completa al 20 % y un guion de 16 de 62.8 encima, 800 ms.
            reloj(800) { fase in
                ZStack {
                    Circle().stroke(lineWidth: trazo).opacity(0.2)
                    arco(hasta: 16 / perimetro).rotationEffect(.degrees(fase * 360))
                }
                .frame(width: diametro, height: diametro)
            }
        case "snake":
            // Gira en 1400 ms y, en el mismo tiempo, el guion se estira de 1 a 45 y avanza
            // (0 % 1/0, 50 % 45/−17, 100 % 45/−62 de dasharray/dashoffset), en ease-in-out por
            // tramo. El desfase negativo del SVG es aquí un giro extra del guion.
            reloj(1400) { fase in
                let guion = Self.serpiente(fase)
                arco(hasta: guion.largo / perimetro)
                    .frame(width: diametro, height: diametro)
                    .rotationEffect(.degrees((guion.inicio / perimetro + fase) * 360))
            }
        default:
            // Arco: un guion de 18 de 62.8, 800 ms.
            reloj(800) { fase in
                arco(hasta: 18 / perimetro)
                    .frame(width: diametro, height: diametro)
                    .rotationEffect(.degrees(fase * 360))
            }
        }
    }

    /// El guion de la serpiente en una fase: largo e inicio en unidades del lienzo, con el
    /// ease-in-out de CSS aproximado por tramo (x²(3 − 2x)).
    private static func serpiente(_ fase: Double) -> (largo: Double, inicio: Double) {
        let suave = { (x: Double) in x * x * (3 - 2 * x) }
        if fase < 0.5 { let u = suave(fase / 0.5); return (1 + 44 * u, 17 * u) }
        let u = suave((fase - 0.5) / 0.5)
        return (45, 17 + 45 * u)
    }

    /// Un tramo del círculo desde las 3 en punto, con el trazo y las puntas redondas de loading.dev.
    private func arco(hasta: Double) -> some View {
        Circle()
            .trim(from: 0, to: hasta)
            .stroke(style: StrokeStyle(lineWidth: trazo, lineCap: .round))
    }

    /// Fase de 0 a 1 que da la vuelta cada `ms` milisegundos. Con "reducir movimiento", quieta.
    private func reloj<Contenido: View>(_ ms: Double, @ViewBuilder _ contenido: @escaping (Double) -> Contenido) -> some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate * 1000
            contenido(reduceMotion ? 0.3 : t.truncatingRemainder(dividingBy: ms) / ms)
        }
    }
}
