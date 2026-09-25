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
//  Se reordena arrastrando (las demás se hacen a un lado mientras tanto) y se puede llevar una
//  pestaña a otro Space; al soltar, entra junto a la que queda antes, en su misma sección, igual
//  que en la tira de arriba. Al final de cada Space, «Nueva pestaña».
//
//  Las miniaturas son la última imagen de cada pestaña (KurthCapturas). La de la pestaña actual
//  se toma al abrir; las demás, de cuando se vieron por última vez: WebKit no dibuja las páginas
//  que no están a la vista.
//

import SwiftUI
import UniformTypeIdentifiers
import NookDesign
import NookWeb
import NookUI
import NookTabsCore

struct KurthCuadricula: View {
    @Environment(BrowserWindowState.self) private var ventana
    @Environment(CommandPalette.self) private var commandPalette
    @EnvironmentObject private var browserManager: BrowserManager

    /// Dónde caería la pestaña que se arrastra: antes de otra, o al final de un Space.
    enum Destino: Equatable {
        case antesDe(UUID)
        case alFinal(UUID)
    }

    @State private var arrastrando: Item?
    @State private var destino: Destino?

    /// Solo dentro de Nook: que soltarla en otro lado no la tome por texto.
    static let tipo = UTType(exportedAs: "com.kurthwalther.nook.pestana")

    var body: some View {
        let gestos = KurthGestos.de(ventana)
        if gestos.progreso > 0 {
            contenido(gestos)
                .opacity(Double(gestos.progreso))
                .scaleEffect(1.04 - 0.04 * gestos.progreso)
                .allowsHitTesting(gestos.progreso >= 1)
                .onDisappear { arrastrando = nil; destino = nil }
        }
    }

    private func contenido(_ gestos: KurthGestos) -> some View {
        let tabs = browserManager.tabs
        // El Space de la ventana primero; luego los demás en su orden. Con varios, también los
        // vacíos: ahí se puede soltar una pestaña o abrir una nueva.
        let todos = tabs.switchableSpaces(for: ventana)
        let espacios = todos.filter { $0.id == ventana.spaceID } + todos.filter { $0.id != ventana.spaceID }

        return ZStack {
            KurthHoverTheme()
                .contentShape(Rectangle())
                .onTapGesture { gestos.cerrarCuadricula() }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(espacios) { espacio in
                        VStack(alignment: .leading, spacing: 12) {
                            if espacios.count > 1 {
                                Text(espacio.name)
                                    .font(NookDesign.Font.title.weight(.semibold))
                                    .foregroundStyle(Color.primary.opacity(0.8))
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 18)],
                                      alignment: .leading, spacing: 18) {
                                ForEach(lista(espacio.id), id: \.id) { item in
                                    KurthCeldaDePestaña(item: item, gestos: gestos)
                                        .onDrag {
                                            arrastrando = item
                                            destino = nil
                                            return Self.proveedor(item)
                                        }
                                        .onDrop(of: [Self.tipo], delegate: KurthSoltarEnCuadricula(
                                            aqui: .antesDe(item.id), arrastrado: arrastrando?.id,
                                            destino: $destino, soltar: soltar))
                                }
                                celdaNueva(espacio.id, gestos: gestos)
                                    .onDrop(of: [Self.tipo], delegate: KurthSoltarEnCuadricula(
                                        aqui: .alFinal(espacio.id), arrastrado: arrastrando?.id,
                                        destino: $destino, soltar: soltar))
                            }
                            .animation(.spring(duration: 0.28, bounce: 0.1), value: destino)
                        }
                    }
                }
                .padding(.horizontal, 28)
                // Libra los botones de la ventana y la barra de arriba.
                .padding(.top, 56)
                .padding(.bottom, 28)
            }
            .scrollEdgeEffectHidden(true, for: .vertical)
            // Soltar entre celdas o en el fondo cuenta con el último lugar que se marcó.
            .onDrop(of: [Self.tipo], delegate: KurthSoltarEnCuadricula(
                aqui: nil, arrastrado: arrastrando?.id, destino: $destino, soltar: soltar))
        }
    }

    // MARK: - Reordenar

    /// Las pestañas de un Space como se ven: si hay una arrastrándose, ya en el lugar donde caería.
    private func lista(_ espacio: UUID) -> [Item] {
        var lista = KurthGestos.pestañas(browserManager.tabs, espacio: espacio)
        guard let arrastrando, let destino else { return lista }
        lista.removeAll { $0.id == arrastrando.id }
        switch destino {
        case .antesDe(let id):
            if let i = lista.firstIndex(where: { $0.id == id }) { lista.insert(arrastrando, at: i) }
        case .alFinal(let id):
            if id == espacio { lista.append(arrastrando) }
        }
        return lista
    }

    /// Al soltar: entra después de la que le queda antes y en su misma sección (favoritos,
    /// guardados, del día o una carpeta), como al reordenar la tira. Si queda primera, al principio
    /// de la sección de la que tiene delante.
    private func soltar() {
        defer { arrastrando = nil; destino = nil }
        guard let arrastrando, let destino else { return }
        let tabs = browserManager.tabs
        switch destino {
        case .alFinal(let espacio):
            let seccion = Parent.tabs(spaceID: espacio)
            let ultima = tabs.children(of: seccion).last { $0.id != arrastrando.id }
            tabs.move(arrastrando.id, to: seccion, after: ultima?.id)
        case .antesDe(let id):
            guard let espacio = tabs.spaceID(of: id) else { return }
            let lista = lista(espacio)
            guard let i = lista.firstIndex(where: { $0.id == arrastrando.id }) else { return }
            let previa = i > 0 ? lista[i - 1] : nil
            let seccion = previa?.parent ?? lista.first { $0.id != arrastrando.id }?.parent ?? .tabs(spaceID: espacio)
            tabs.move(arrastrando.id, to: seccion, after: previa?.id)
        }
    }

    private static func proveedor(_ item: Item) -> NSItemProvider {
        let proveedor = NSItemProvider()
        proveedor.registerDataRepresentation(forTypeIdentifier: tipo.identifier, visibility: .ownProcess) { listo in
            listo(Data(item.id.uuidString.utf8), nil)
            return nil
        }
        return proveedor
    }

    // MARK: - Nueva pestaña

    /// La última celda de cada Space: abre el campo de dirección para una pestaña nueva ahí.
    private func celdaNueva(_ espacio: UUID, gestos: KurthGestos) -> some View {
        let forma = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            gestos.cerrarCuadricula()
            if ventana.spaceID != espacio { browserManager.tabs.setSpace(espacio, in: ventana) }
            commandPalette.open()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                forma
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(Color.primary.opacity(destino == .alFinal(espacio) ? 0.4 : 0.18))
                    .background(forma.fill(Color.primary.opacity(destino == .alFinal(espacio) ? 0.06 : 0.02)))
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.45))
                    }
                    .aspectRatio(16 / 10, contentMode: .fit)
                Text("Nueva pestaña")
                    .font(NookDesign.Font.secondary)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                    .frame(height: NookDesign.Size.favicon)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Nueva pestaña en este Space")
    }
}

/// Soltar en la cuadrícula. Al entrar a una celda marca ese lugar (las demás se reacomodan); la
/// celda de la propia pestaña no cuenta, o se quitaría a sí misma de la lista. `aqui` nil es el
/// fondo: no marca nada y al soltar usa el último lugar marcado.
private struct KurthSoltarEnCuadricula: DropDelegate {
    let aqui: KurthCuadricula.Destino?
    let arrastrado: UUID?
    @Binding var destino: KurthCuadricula.Destino?
    let soltar: () -> Void

    func validateDrop(info: DropInfo) -> Bool { arrastrado != nil }

    func dropEntered(info: DropInfo) {
        guard let aqui, arrastrado != nil, aqui != .antesDe(arrastrado!), destino != aqui else { return }
        destino = aqui
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        soltar()
        return true
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
