// Licensed under GPL-3.0. See LICENSE.
//
//  KurthCabezaAviso.swift
//  Nook (rama kurth)
//
//  La cápsula que dice "el agente está trabajando aquí" sobre la página que maneja (KurthCabeza).
//  Kurth vio en la maqueta un velo oscuro sobre toda la página y pidió algo más sutil (26 sep):
//  queda solo esta cápsula, del mismo vidrio que las de la barra (KurthGlass), abajo al centro,
//  donde no tapa la barra ni el contenido de arriba que el agente suele estar llenando.
//
//  No bloquea la página. Detener existe para cuando Kurth quiere que pare, no para impedirle
//  tocar: si él da clic mientras el agente trabaja, es porque quiere; y un velo que se come los
//  clics convierte cada turno del agente en una pantalla congelada.
//
//  Un solo movimiento para entrar y salir: fundido con escala 0.96 → 1 anclada abajo, con el
//  resorte de NookDesign.Motion. Con "Reducir movimiento", solo el fundido y el punto quieto.
//

import SwiftUI
import NookDesign
import NookUI
import NookWeb

struct KurthCabezaAviso: View {
    @EnvironmentObject private var browserManager: BrowserManager
    @EnvironmentObject private var splitManager: SplitViewManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(KurthCabeza.clave) private var activo = true

    var body: some View {
        GeometryReader { geo in
            let centro = activo ? centroX(ancho: geo.size.width) : nil
            ZStack(alignment: .bottom) {
                if let centro {
                    KurthCabezaCapsula()
                        .offset(x: centro - geo.size.width / 2)
                        .padding(.bottom, NookDesign.Spacing.xl)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .animation(reduceMotion ? KurthMotion.reduced : NookDesign.Motion.spring, value: centro)
        }
    }

    /// Dónde va la cápsula: al centro de la página si la controlada es la que muestra esta ventana;
    /// con split, al centro de su mitad. nil si la controlada no está a la vista aquí (entonces lo
    /// dice solo el anillo de su pestaña).
    private func centroX(ancho: CGFloat) -> CGFloat? {
        guard let controlada = KurthCabezaGancho.shared.controlada else { return nil }
        if splitManager.isSplit(for: windowState.id) {
            let f = splitManager.dividerFraction(for: windowState.id)
            if controlada == splitManager.leftTabId(for: windowState.id) { return ancho * f / 2 }
            if controlada == splitManager.rightTabId(for: windowState.id) { return ancho * f + ancho * (1 - f) / 2 }
            return nil
        }
        return browserManager.tabs.selectedItemID(in: windowState) == controlada ? ancho / 2 : nil
    }
}

/// El contenido: punto que respira, la frase y Detener. Alto de las cápsulas de la barra.
private struct KurthCabezaCapsula: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            // El símbolo con su efecto lo anima Core Animation: no redibuja la vista en cada cuadro
            // (un TimelineView aquí gastaría batería mientras el agente trabaja minutos).
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.breathe.pulse, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text("Trabajando en esta pestaña")
                .font(NookDesign.Font.secondary)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
            BotonDetener()
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: KurthTopBarView.capsuleHeight)
        .modifier(KurthGlass(tint: nil))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("El agente está trabajando en esta pestaña")
    }
}

/// Un botón dentro de la cápsula: su propio relleno más oscuro, concéntrico con ella (4 pt de aire
/// alrededor), como el segmento elegido de la tira. Se oscurece un poco con el mouse encima.
private struct BotonDetener: View {
    @State private var encima = false

    var body: some View {
        Button {
            KurthCabeza.shared.detener()
        } label: {
            Text("Detener")
                .font(NookDesign.Font.secondary)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: KurthTopBarView.capsuleHeight - 8)
                .background(Capsule().fill(.primary.opacity(encima ? 0.14 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHoverTracking { encima = $0 }
        .animation(NookDesign.Motion.quick, value: encima)
        .help("Detiene al agente. La página se queda como está.")
    }
}
