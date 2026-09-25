// Licensed under GPL-3.0. See LICENSE.
//
//  KurthReloadButton.swift
//  Nook (rama kurth)
//
//  Recargar / cargando / detener. Mientras la página carga se ve un indicador que gira, no la X;
//  la X (detener) solo aparece al pasar el mouse por encima (Kurth, 25 sep: "debería ser un icono
//  de cargando, y si te pones arriba, la X"). Lo comparten la barra (KurthTopBarView, en las dos
//  variantes) y la tira compacta (KurthTabStrip); cada sitio le pone su estilo de ícono.
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
            if cargando { session?.stop() } else { session?.refresh() }
        } label: {
            Label {
                Text(cargando ? "Detener" : "Recargar")
            } icon: {
                if cargando && !alPasar {
                    // El símbolo de progreso de SF con su efecto de color por capas: gira al ritmo
                    // del sistema y toma el mismo gris que los demás íconos de la barra.
                    Image(systemName: "progress.indicator")
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, isActive: true)
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
