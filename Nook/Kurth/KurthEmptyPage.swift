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

/// El espacio de la URL cuando no hay pestaña: escribes una dirección o una búsqueda y se abre
/// en una pestaña nueva, igual que desde la paleta (CommandPaletteView.selectSuggestion:
/// normalizeURL con el buscador de los ajustes). Sin sugerencias: para eso está ⌘T.
struct KurthAddressInput: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    @State private var texto = ""
    @FocusState private var enfocado: Bool

    static let width: CGFloat = 300

    var body: some View {
        HStack(spacing: NookDesign.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(NookDesign.Font.caption)
                .foregroundStyle(.secondary)
            TextField("Busca o escribe una dirección", text: $texto)
                .textFieldStyle(.plain)
                .font(NookDesign.Font.body)
                .focused($enfocado)
                .onSubmit(abrir)
        }
        .padding(.horizontal, 12)
        .frame(width: Self.width, height: KurthTopBarView.capsuleHeight)
        .contentShape(Capsule())
        .onTapGesture { enfocado = true }
        .onAppear { enfocado = true }
    }

    private func abrir() {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { return }
        let plantilla = browserManager.nookSettings?.resolvedSearchEngineTemplate ?? SearchProvider.google.queryTemplate
        guard let url = URL(string: normalizeURL(limpio, queryTemplate: plantilla)) else { return }
        browserManager.tabs.open(url: url, in: windowState, placement: .newTab)
        texto = ""
    }
}
