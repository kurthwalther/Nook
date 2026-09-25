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
//  Se reordena arrastrando: la miniatura sigue al mouse y las demás se hacen a un lado. Se puede
//  llevar a otro Space; al soltar entra junto a la que queda antes, en su misma sección, igual
//  que en la tira de arriba. Es un DragGesture simultáneo, como el de la tira: el arrastre del
//  sistema (onDrag) no arrancaba sobre un botón (probado el 25 sep).
//
//  Al final de cada Space, «Nueva pestaña»: abre el campo de dirección encima de la cuadrícula,
//  que sigue abierta detrás; se cierra sola cuando la pestaña nueva queda elegida.
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
    @Environment(CommandPalette.self) private var commandPalette
    @EnvironmentObject private var browserManager: BrowserManager

    /// Dónde caería la pestaña que se arrastra: en qué Space y en qué lugar de su lista (contada
    /// sin ella).
    struct Destino: Equatable {
        let espacio: UUID
        let indice: Int
    }

    @State private var arrastrando: Item?
    @State private var destino: Destino?
    /// Dónde va el mouse y dónde se agarró la miniatura, en el espacio de la cuadrícula.
    @State private var puntero: CGPoint = .zero
    @State private var agarre: CGSize = .zero
    /// El marco de cada celda (las de «Nueva pestaña», con el id de su Space).
    @State private var marcos: [UUID: CGRect] = [:]
    /// La última celda en la que entró el mouse: se reacomoda al entrar a otra, no a cada paso.
    @State private var sobre: UUID?
    /// El clic del mismo soltar no cuenta como elegir la pestaña.
    @State private var recienArrastrada = false
    /// Se pidió una pestaña nueva: la que estaba elegida al abrir el campo.
    @State private var esperandoNueva: UUID??

    var body: some View {
        let gestos = KurthGestos.de(ventana)
        if gestos.progreso > 0 {
            contenido(gestos)
                .opacity(Double(gestos.progreso))
                .scaleEffect(1.04 - 0.04 * gestos.progreso)
                .allowsHitTesting(gestos.progreso >= 1)
                .onAppear { gestos.paleta = commandPalette }
                .onDisappear {
                    arrastrando = nil
                    destino = nil
                    esperandoNueva = nil
                    marcos = [:] // de pestañas que quizá ya no existan
                }
                // La pestaña nueva ya quedó elegida: a ella.
                .onChange(of: browserManager.tabs.selectedItemID(in: ventana)) { _, elegida in
                    guard let antes = esperandoNueva, elegida != antes else { return }
                    esperandoNueva = nil
                    gestos.cerrarCuadricula()
                }
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
                                    KurthCeldaDePestaña(item: item) {
                                        guard !recienArrastrada else { return }
                                        gestos.elegir(item.id)
                                    }
                                    // Su lugar se queda como fantasma mientras la copia sigue al mouse.
                                    .opacity(arrastrando?.id == item.id ? 0.25 : 1)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("cuadricula")) } action: { marcos[item.id] = $0 }
                                    .simultaneousGesture(arrastre(item))
                                }
                                celdaNueva(espacio.id)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("cuadricula")) } action: { marcos[espacio.id] = $0 }
                            }
                            .animation(.spring(duration: 0.28, bounce: 0.1), value: destino)
                        }
                    }
                }
                .padding(.horizontal, 28)
                // Libra los botones de la ventana y la barra de arriba.
                .padding(.top, 56)
                .padding(.bottom, 28)
                .coordinateSpace(name: "cuadricula")
                // La copia que sigue al mouse.
                .overlay(alignment: .topLeading) {
                    if let arrastrando, let marco = marcos[arrastrando.id] {
                        KurthCeldaDePestaña(item: arrastrando) {}
                            .frame(width: marco.width, height: marco.height)
                            .scaleEffect(1.04)
                            .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
                            .offset(x: puntero.x - agarre.width, y: puntero.y - agarre.height)
                            .allowsHitTesting(false)
                    }
                }
            }
            .scrollEdgeEffectHidden(true, for: .vertical)
        }
    }

    // MARK: - Reordenar

    /// Las pestañas de un Space como se ven: si hay una arrastrándose, ya en el lugar donde caería.
    private func lista(_ espacio: UUID) -> [Item] {
        var lista = KurthGestos.pestañas(browserManager.tabs, espacio: espacio)
        guard let arrastrando, let destino else { return lista }
        lista.removeAll { $0.id == arrastrando.id }
        if destino.espacio == espacio { lista.insert(arrastrando, at: min(destino.indice, lista.count)) }
        return lista
    }

    private func arrastre(_ item: Item) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("cuadricula"))
            .onChanged { valor in
                if arrastrando?.id != item.id {
                    let origen = marcos[item.id]?.origin ?? valor.startLocation
                    agarre = CGSize(width: valor.startLocation.x - origen.x, height: valor.startLocation.y - origen.y)
                    recienArrastrada = true
                    sobre = nil
                    if let espacio = browserManager.tabs.spaceID(of: item.id),
                       let i = KurthGestos.pestañas(browserManager.tabs, espacio: espacio).firstIndex(where: { $0.id == item.id }) {
                        destino = Destino(espacio: espacio, indice: i)
                    }
                    arrastrando = item
                }
                puntero = valor.location
                reacomodar(en: valor.location)
            }
            .onEnded { _ in
                soltar()
                // El botón dispara con el mismo mouse-up que termina el arrastre: se deja pasar.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { recienArrastrada = false }
            }
    }

    /// Al entrar a otra celda: la arrastrada toma su lugar. Si venía de antes, queda después de
    /// ella; si venía de después, antes (así se mueve hacia donde va el mouse).
    private func reacomodar(en punto: CGPoint) {
        guard let arrastrando else { return }
        let bajo = marcos.first { $0.key != arrastrando.id && $0.value.contains(punto) }?.key
        guard bajo != sobre else { return }
        sobre = bajo
        guard let bajo else { return }
        let tabs = browserManager.tabs
        let nuevo: Destino
        if tabs.space(bajo) != nil {
            // «Nueva pestaña» de ese Space: al final.
            let sinElla = lista(bajo).filter { $0.id != arrastrando.id }
            nuevo = Destino(espacio: bajo, indice: sinElla.count)
        } else {
            guard let espacio = tabs.spaceID(of: bajo) else { return }
            let actual = lista(espacio)
            let sinElla = actual.filter { $0.id != arrastrando.id }
            guard let q = actual.firstIndex(where: { $0.id == bajo }),
                  let qSinElla = sinElla.firstIndex(where: { $0.id == bajo }) else { return }
            let p = actual.firstIndex { $0.id == arrastrando.id }
            nuevo = Destino(espacio: espacio, indice: p.map { q > $0 } == true ? qSinElla + 1 : qSinElla)
        }
        if nuevo != destino { destino = nuevo }
    }

    /// Al soltar: entra después de la que le queda antes y en su misma sección (favoritos,
    /// guardados, del día o una carpeta), como al reordenar la tira. Si queda primera, al principio
    /// de la sección de la que tiene delante; sola en un Space vacío, a las del día.
    private func soltar() {
        defer {
            var sinAnimar = Transaction()
            sinAnimar.disablesAnimations = true
            withTransaction(sinAnimar) {
                arrastrando = nil
                destino = nil
                sobre = nil
            }
        }
        guard let arrastrando, let destino else { return }
        let lista = lista(destino.espacio)
        guard let i = lista.firstIndex(where: { $0.id == arrastrando.id }) else { return }
        let previa = i > 0 ? lista[i - 1] : nil
        let siguiente = i + 1 < lista.count ? lista[i + 1] : nil
        let seccion = previa?.parent ?? siguiente?.parent ?? .tabs(spaceID: destino.espacio)
        guard seccion != arrastrando.parent || previa?.id != anterior(de: arrastrando) else { return }
        browserManager.tabs.move(arrastrando.id, to: seccion, after: previa?.id)
    }

    /// La que tenía antes en el orden guardado, para no mover nada si se soltó donde estaba.
    private func anterior(de item: Item) -> UUID? {
        guard let espacio = browserManager.tabs.spaceID(of: item.id) else { return nil }
        let guardada = KurthGestos.pestañas(browserManager.tabs, espacio: espacio)
        guard let i = guardada.firstIndex(where: { $0.id == item.id }), i > 0 else { return nil }
        return guardada[i - 1].id
    }

    // MARK: - Nueva pestaña

    /// La última celda de cada Space: el campo de dirección para una pestaña nueva ahí, encima de
    /// la cuadrícula (Kurth, 25 sep: "debería abrir el pop up sobre esa vista").
    private func celdaNueva(_ espacio: UUID) -> some View {
        let forma = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let marcada = arrastrando != nil && sobre == espacio
        return Button {
            if ventana.spaceID != espacio { browserManager.tabs.setSpace(espacio, in: ventana) }
            esperandoNueva = .some(browserManager.tabs.selectedItemID(in: ventana))
            commandPalette.open()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                forma
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(Color.primary.opacity(marcada ? 0.4 : 0.18))
                    .background(forma.fill(Color.primary.opacity(marcada ? 0.06 : 0.02)))
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

/// Una pestaña: su imagen en proporción 16:10, el ícono y el título. Al pasar el mouse, la X para
/// cerrarla y un leve realce; la actual lleva el borde de acento.
private struct KurthCeldaDePestaña: View {
    let item: Item
    let elegir: () -> Void
    @Environment(BrowserWindowState.self) private var ventana
    @EnvironmentObject private var browserManager: BrowserManager
    @State private var encima = false

    private var esActual: Bool { browserManager.tabs.selectedItemID(in: ventana) == item.id }
    private let forma = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        let tabs = browserManager.tabs
        Button(action: elegir) {
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
