// Licensed under GPL-3.0. See LICENSE.
//
//  KurthPanelMaterial.swift
//  Nook (rama kurth)
//
//  Un solo material para las cuatro barras: la lateral y el agente, fijos y con hover (Kurth,
//  25 sep: "que ese toggle afecte todos los sidebar… quiero ver las diferencias"). El ajuste es
//  kurth.panelMaterial y se cambia con ◐ en el encabezado del agente:
//
//  · glass — Liquid Glass, el material de macOS 26 para lo que flota sobre el contenido (las
//    barras laterales de Finder o Mail en Tahoe, las cápsulas de nuestra barra). En los flotantes
//    va con el tema encima a `velo` para que el texto se lea sobre una página movida. En los fijos
//    es un panel de vidrio separado de las orillas, sobre el fondo del tema de la ventana.
//  · panel — lo de antes: los fijos no tienen fondo propio (se ve el de la ventana, KurthWindowTheme)
//    y los flotantes llevan ese mismo material difuminando la página (KurthHoverTheme).
//

import SwiftUI
import NookDesign

enum KurthPanelMaterial {
    static let clave = "kurth.panelMaterial"
    static let porDefecto = "glass"

    /// Cuánto del tema va sobre el vidrio en los flotantes. El tema solo ya es casi opaco (0.75,
    /// KurthTheme.opacity) y taparía el vidrio; sin nada, el texto largo se pierde sobre una
    /// página movida.
    static let velo = 0.55
}

/// Para lo que flota sobre la página con hover: la barra lateral y la tarjeta del agente.
struct KurthMaterialFlotante: ViewModifier {
    @AppStorage(KurthPanelMaterial.clave) private var material = KurthPanelMaterial.porDefecto

    func body(content: Content) -> some View {
        if material == "glass" {
            content
                .background { KurthHoverTheme(soloTema: true).opacity(KurthPanelMaterial.velo) }
                .clipShape(KurthChrome.overlayShape)
                .glassEffect(.regular, in: KurthChrome.overlayShape)
                .nookElevation(.floating)
        } else {
            content
                .background { KurthHoverTheme() }
                .clipShape(KurthChrome.overlayShape)
                .nookElevation(.floating)
        }
    }
}

/// Para las barras fijas: con vidrio, un panel separado de las orillas por la misma distancia que
/// los flotantes (y concéntrico con la ventana); sin él, nada, como siempre.
struct KurthMaterialFijo: ViewModifier {
    @AppStorage(KurthPanelMaterial.clave) private var material = KurthPanelMaterial.porDefecto

    func body(content: Content) -> some View {
        content.background {
            if material == "glass" {
                Color.clear
                    .glassEffect(.regular, in: KurthChrome.overlayShape)
                    .padding(KurthChrome.overlayInset)
                    .allowsHitTesting(false)
            }
        }
    }
}
