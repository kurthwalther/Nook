// Licensed under GPL-3.0. See LICENSE.
//
//  KurthPageEdge.swift
//  Nook (rama kurth)
//
//  Sombra ligera bajo la tarjeta de la página, como la de Zen 1.22 (rgba(0,0,0,.24) 0 3px 8px;
//  el blur de 8 px de CSS es radius 4 en SwiftUI). Va en una forma hermana DETRÁS de la
//  tarjeta y no en el grupo del WKWebView: una sombra ahí se recalcula sobre una capa del
//  tamaño de la página en cada cuadro de scroll o de video.
//

import SwiftUI
import NookDesign

struct KurthPageEdge: View {
    /// Intensidad ajustable (se aplica al reiniciar Nook).
    @AppStorage("kurth.pageShadow") private var opacity = 0.24

    var body: some View {
        NookDesign.Radius.shape(NookDesign.Radius.md)
            .fill(NookDesign.Surface.windowBackground)
            .shadow(color: .black.opacity(opacity), radius: 4, y: 3)
            .allowsHitTesting(false)
    }
}
