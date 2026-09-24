// Licensed under GPL-3.0. See LICENSE.
//
//  KurthEmptyPage.swift
//  Nook (rama kurth)
//
//  Sin ninguna pestaña: la página queda transparente con "Ah, peace." (el tema se ve continuo),
//  y lo demás lo resuelve el resto de la ventana, como en Arc: la barra lateral se queda a la
//  vista aunque esté oculta (HoverSidebarManager) y el espacio de la URL de la barra de arriba
//  es un campo listo para escribir (KurthAddressInput). Kurth lo decidió el 24 sep, después de
//  ver una tarjeta con buscador al centro.
//

import SwiftUI
import NookDesign
import NookSettings
import NookWeb

struct KurthEmptyPage: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.stars")
                .font(NookDesign.Font.display)
                .blendMode(.overlay)
            Text("Ah, peace.")
                .font(NookDesign.Font.title)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// El espacio de la URL cuando no hay pestaña: se ve como el campo de la barra, pero al tocarlo
/// abre la paleta flotante de Nook (la misma de ⌘T y de "New Tab"), con sus sugerencias. Antes
/// era un campo de texto en línea, y Kurth no lo quiso así (24 sep): la paleta ya existe.
struct KurthAddressInput: View {
    @Environment(CommandPalette.self) private var commandPalette
    @State private var alPasar = false

    static let width: CGFloat = 300

    var body: some View {
        HStack(spacing: NookDesign.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(NookDesign.Font.caption)
                .foregroundStyle(.secondary)
            Text("Busca o escribe una dirección")
                .font(NookDesign.Font.body)
                .foregroundStyle(alPasar ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: Self.width, height: KurthTopBarView.capsuleHeight)
        .contentShape(Capsule())
        .onTapGesture { commandPalette.open() }
        .onHoverTracking { alPasar = $0 }
        .animation(NookDesign.Motion.quick, value: alPasar)
    }
}
