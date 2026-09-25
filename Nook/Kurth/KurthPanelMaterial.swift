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
//    cambia el material del fondo de la ventana, que es el suyo (KurthVidrioDeVentana): un panel
//    de vidrio encima hacía doble fondo (Kurth, 25 sep).
//  · panel — lo de antes: los fijos no tienen fondo propio (se ve el de la ventana, KurthWindowTheme)
//    y los flotantes llevan ese mismo material difuminando la página (KurthHoverTheme).
//

import SwiftUI
import NookDesign
import NookWeb
import NookWeb

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

/// Las barras fijas no tienen fondo propio: son el fondo de la ventana (KurthWindowTheme). Con
/// vidrio, todo ese fondo pasa a Liquid Glass de orilla a orilla, con las esquinas de la ventana
/// (Kurth, 25 sep: "el fondo de toda la pantalla pasarse a liquid"). Solo mientras se vea: con una
/// barra fija abierta o sin pestaña ("Ah, peace."). Si no, la página lo tapa todo y la capa se
/// calcularía para nada.
struct KurthVidrioDeVentana: View {
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(TabsController.self) private var tabs
    @AppStorage(KurthPanelMaterial.clave) private var material = KurthPanelMaterial.porDefecto

    private var seVe: Bool {
        windowState.isSidebarVisible || windowState.isSidebarAIChatVisible
            || tabs.selectedSession(in: windowState) == nil
    }

    var body: some View {
        if material == "glass", seVe {
            Color.clear
                .glassEffect(.regular, in: ConcentricRectangle())
                .allowsHitTesting(false)
        }
    }
}
