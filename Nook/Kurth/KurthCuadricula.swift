// Licensed under GPL-3.0. See LICENSE.
//
//  KurthCuadricula.swift
//  Nook (rama kurth)
//
//  Todas las pestañas en miniatura, agrupadas por Space (Kurth, 25 sep). Se abre pellizcando la
//  página o con ⇧⌘\ y entra siguiendo los dedos (KurthGestos.progreso). Un clic lleva a la
//  pestaña, aunque sea de otro Space; la X la cierra; Esc, abrir los dedos o un clic en el fondo
//  la cierran. Cubre la columna de la página: la barra lateral y el agente siguen a la mano.
//
//  Las miniaturas son la última imagen de cada pestaña (KurthCapturas). La de la pestaña actual
//  se toma al abrir; las demás, de cuando se vieron por última vez: WebKit no dibuja las páginas
//  que no están a la vista.
//

import SwiftUI
import NookDesign
import NookWeb
import NookUI
import NookTabsCore

struct KurthCuadricula: View {
    @Environment(BrowserWindowState.self) private var ventana
    @EnvironmentObject private var browserManager: BrowserManager

    var body: some View {
        let gestos = KurthGestos.de(ventana)
        if gestos.progreso > 0 {
            contenido(gestos)
                .opacity(Double(gestos.progreso))
                .scaleEffect(1.04 - 0.04 * gestos.progreso)
                .allowsHitTesting(gestos.progreso >= 1)
        }
    }

    private func contenido(_ gestos: KurthGestos) -> some View {
        let tabs = browserManager.tabs
        // El Space de la ventana primero; luego los demás en su orden.
        let todos = tabs.switchableSpaces(for: ventana)
        let espacios = (todos.filter { $0.id == ventana.spaceID } + todos.filter { $0.id != ventana.spaceID })
            .map { (espacio: $0, pestañas: KurthGestos.pestañas(tabs, espacio: $0.id)) }
            .filter { !$0.pestañas.isEmpty }

        return ZStack {
            KurthHoverTheme()
                .contentShape(Rectangle())
                .onTapGesture { gestos.cerrarCuadricula() }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(espacios, id: \.espacio.id) { grupo in
                        VStack(alignment: .leading, spacing: 12) {
                            if espacios.count > 1 {
                                Text(grupo.espacio.name)
                                    .font(NookDesign.Font.title.weight(.semibold))
                                    .foregroundStyle(Color.primary.opacity(0.8))
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 18)],
                                      alignment: .leading, spacing: 18) {
                                ForEach(grupo.pestañas, id: \.id) { item in
                                    KurthCeldaDePestaña(item: item, gestos: gestos)
                                }
                            }
                        }
                    }
                    if espacios.isEmpty {
                        Text("No hay pestañas abiertas")
                            .font(NookDesign.Font.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }
                }
                .padding(.horizontal, 28)
                // Libra los botones de la ventana y la barra de arriba.
                .padding(.top, 56)
                .padding(.bottom, 28)
            }
            .scrollEdgeEffectHidden(true, for: .vertical)
        }
    }
}

/// Una pestaña: su imagen en proporción 16:10, el ícono y el título. Al pasar el mouse, la X para
/// cerrarla y un leve realce; la actual lleva el borde de acento.
private struct KurthCeldaDePestaña: View {
    let item: Item
    let gestos: KurthGestos
    @Environment(BrowserWindowState.self) private var ventana
    @EnvironmentObject private var browserManager: BrowserManager
    @State private var encima = false

    private var esActual: Bool { browserManager.tabs.selectedItemID(in: ventana) == item.id }
    private let forma = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        let tabs = browserManager.tabs
        Button { gestos.elegir(item.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                miniatura
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(forma)
                    .overlay {
                        forma.strokeBorder(esActual ? Color.accentColor : Color.primary.opacity(0.08),
                                           lineWidth: esActual ? 2 : 0.5)
                    }
                    .shadow(color: .black.opacity(encima ? 0.18 : 0.1), radius: encima ? 10 : 5, y: encima ? 4 : 2)
                    .overlay(alignment: .topLeading) {
                        if encima {
                            Button("Cerrar pestaña", systemImage: "xmark") { tabs.close(item.id) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(.regularMaterial, in: Circle())
                                .padding(6)
                                .transition(.opacity)
                        }
                    }
                HStack(spacing: 6) {
                    ItemFavicon(item: item, session: tabs.session(for: item.id))
                        .frame(width: NookDesign.Size.favicon, height: NookDesign.Size.favicon)
                    Text(tabs.title(for: item))
                        .font(NookDesign.Font.secondary)
                        .foregroundStyle(Color.primary.opacity(esActual ? 0.95 : 0.75))
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .scaleEffect(encima ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHoverTracking { dentro in withAnimation(NookDesign.Motion.quick) { encima = dentro } }
        .help(tabs.currentURL(for: item)?.absoluteString ?? tabs.title(for: item))
    }

    @ViewBuilder
    private var miniatura: some View {
        if let imagen = KurthCapturas.shared.miniatura(item.id) {
            Image(nsImage: imagen)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
                .background(Color(nsColor: .textBackgroundColor))
        } else {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                ItemFavicon(item: item, session: browserManager.tabs.session(for: item.id))
                    .frame(width: 28, height: 28)
                    .opacity(0.8)
            }
        }
    }
}
