// Licensed under GPL-3.0. See LICENSE.
//
//  KurthTabStrip.swift
//  Nook (rama kurth)
//
//  Pestañas compactas como las de Safari 15 (macOS Monterey): las pestañas del Space viven en la
//  misma cápsula que la dirección, como segmentos de un control segmentado. La activa es la cápsula
//  de siempre (dominio y recargar) con un relleno que la distingue; las demás, ícono y título, o
//  solo ícono si Kurth lo pide (kurth.compactTabs = icons, como en iPad). Los favoritos van igual
//  que el resto: Kurth no quiso que se encogieran solos (24 sep).
//  La tira mide lo que mide su contenido y va centrada, como la cápsula sola (Kurth, 24 sep: "no
//  hacerse una barra enorme"). Si no cabe, se desplaza de lado en vez de encimarse a los botones.
//  Se reordenan arrastrando: el segmento sigue al mouse, los demás se hacen a un lado y al soltar
//  se llama al mismo `move` del sidebar; soltar junto a un favorito lo vuelve favorito.
//  Se enciende con kurth.tabLayout = compact (clic derecho en la barra o kurth_set_settings).
//

import SwiftUI
import NookDesign
import NookTabsCore
import NookWeb
import NookUI

struct KurthTabStrip: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(CommandPalette.self) private var commandPalette

    /// Vidrio (barra "capsules") o relleno plano (barra "tinted").
    let glass: Bool
    let tint: Color?
    /// Todas las pestañas menos la activa como ícono, aunque quepa el título.
    let iconsOnly: Bool

    @Namespace private var strip
    @State private var hovered: UUID?
    /// Arrastre para reordenar: qué segmento, cuánto se ha movido y dónde estaba cada uno al
    /// empezar (las medidas en vivo ya incluyen los desplazamientos, así que no sirven).
    @State private var dragging: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var frames: [UUID: CGRect] = [:]
    @State private var dragFrames: [UUID: CGRect] = [:]
    /// Ancho del hueco entre las cápsulas de los lados y de la tira: mientras quepa va centrada
    /// tal cual; solo si no cabe se mete en un ScrollView (que en macOS 26 dibuja su propio efecto
    /// de borde sobre el vidrio, y por eso no se usa siempre).
    @State private var slotWidth: CGFloat = 0
    @State private var stripWidth: CGFloat = 0
    /// Acaba de haber un arrastre: el clic de ese mismo soltar no cuenta como selección.
    @State private var justDragged = false

    private var tabs: TabsController { browserManager.tabs }
    private var selectedID: UUID? { tabs.selectedItemID(in: windowState) }

    /// Un segmento por pestaña: favoritos primero y luego lo que muestra la barra lateral, en su
    /// orden, sin carpetas.
    private struct Entry: Identifiable {
        let item: Item
        var id: UUID { item.id }
    }

    private var entries: [Entry] {
        guard let spaceID = windowState.spaceID else { return [] }
        let favorites = tabs.favorites(of: spaceID).map { Entry(item: $0) }
        let rows = tabs.rows(space: spaceID).filter { !$0.item.isFolder }.map { Entry(item: $0.item) }
        return favorites + rows
    }

    /// Alto del resalte de la pestaña activa: la cápsula (28) menos 3 pt por lado.
    static let segmentHeight: CGFloat = KurthTopBarView.capsuleHeight - 6
    static let segmentInset: CGFloat = 3
    /// Un título de pestaña inactiva no pasa de esto; más largo se corta con puntos.
    static let titleMaxWidth: CGFloat = 150
    /// Aire vertical para que la sombra de la cápsula no se recorte en el ScrollView.
    private static let verticalRoom: CGFloat = 8

    var body: some View {
        Group {
            if slotWidth > 0, stripWidth > slotWidth {
                ScrollView(.horizontal, showsIndicators: false) {
                    capsule.padding(.vertical, Self.verticalRoom)
                }
            } else {
                capsule
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: KurthTopBarView.capsuleHeight + Self.verticalRoom * 2)
        .background {
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { slotWidth = $0 }
        }
    }

    private var capsule: some View {
        let entries = entries
        let insertion = dragging.map { insertionIndex(for: $0, in: entries) }
        return HStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    divider(hidden: dragging != nil || touchesHighlight(entries[index - 1].id) || touchesHighlight(entry.id))
                }
                segment(entry)
                    .offset(x: shift(of: entry.id, in: entries))
                    // Los demás se corren con resorte; el arrastrado sigue al mouse sin retraso.
                    .animation(dragging == entry.id ? nil : NookDesign.Motion.spring, value: insertion)
                    .zIndex(dragging == entry.id ? 1 : 0)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("strip")) } action: { frames[entry.id] = $0 }
                    .simultaneousGesture(reorderGesture(entry, in: entries))
            }
            newTabButton
        }
        .coordinateSpace(name: "strip")
        .padding(.horizontal, Self.segmentInset)
        // El resalte de la activa sigue al segmento seleccionado y se desliza al cambiar.
        .background(alignment: .leading) {
            if let selectedID {
                activePill.matchedGeometryEffect(id: selectedID, in: strip, isSource: false)
            }
        }
        .frame(height: KurthTopBarView.capsuleHeight)
        // Mide lo que mide su contenido: nada se estira para llenar la barra.
        .fixedSize(horizontal: true, vertical: false)
        .clipShape(Capsule())
        .modifier(StripSurface(glass: glass, tint: tint))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
        .animation(NookDesign.Motion.standard, value: selectedID)
        .animation(NookDesign.Motion.quick, value: hovered)
        .animation(NookDesign.Motion.spring, value: dragging)
    }

    // MARK: - Reordenar arrastrando

    private func reorderGesture(_ entry: Entry, in entries: [Entry]) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("strip"))
            .onChanged { value in
                if dragging != entry.id {
                    dragging = entry.id
                    dragFrames = frames
                    justDragged = true
                }
                dragTranslation = value.translation.width
            }
            .onEnded { _ in
                // El botón dispara con el mismo mouse-up que termina el arrastre: se deja pasar.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { justDragged = false }
                let insertion = insertionIndex(for: entry.id, in: entries)
                let others = entries.filter { $0.id != entry.id }
                let previous = insertion > 0 ? others[insertion - 1] : nil
                // Sin nada delante, entra al principio de la sección del primero (o se queda en la suya).
                let parent = previous?.item.parent ?? others.first?.item.parent ?? entry.item.parent
                // Sin animación al soltar: el segmento ya está donde va a quedar, solo cambia de dueño.
                var settle = Transaction()
                settle.disablesAnimations = true
                withTransaction(settle) {
                    dragging = nil
                    dragTranslation = 0
                    if parent != entry.item.parent || previous?.id != previousID(of: entry.id, in: entries) {
                        tabs.move(entry.id, to: parent, after: previous?.id)
                    }
                }
            }
    }

    /// Cuántos de los otros segmentos quedan a la izquierda del centro del que se arrastra.
    private func insertionIndex(for id: UUID, in entries: [Entry]) -> Int {
        guard let frame = dragFrames[id] else { return 0 }
        let center = frame.midX + dragTranslation
        return entries.filter { $0.id != id && (dragFrames[$0.id]?.midX ?? 0) < center }.count
    }

    private func previousID(of id: UUID, in entries: [Entry]) -> UUID? {
        guard let index = entries.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        return entries[index - 1].id
    }

    /// Lo que se desplaza cada segmento mientras uno se arrastra: el arrastrado sigue al mouse y
    /// los que quedan entre su lugar viejo y el nuevo se corren el ancho del arrastrado.
    private func shift(of id: UUID, in entries: [Entry]) -> CGFloat {
        guard let dragging, let from = entries.firstIndex(where: { $0.id == dragging }) else { return 0 }
        if id == dragging { return dragTranslation }
        let width = (dragFrames[dragging]?.width ?? 0) + 1
        let insertion = insertionIndex(for: dragging, in: entries)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return 0 }
        let position = index < from ? index : index - 1
        if position < from && position >= insertion { return width }
        if position >= from && position < insertion { return -width }
        return 0
    }

    /// El segmento seleccionado de un control segmentado: relleno claro con un borde apenas.
    private var activePill: some View {
        Capsule()
            .fill(.primary.opacity(0.12))
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }

    /// Los separadores desaparecen junto a la pestaña activa y a la que tiene el mouse encima,
    /// como en el control segmentado de Apple.
    private func touchesHighlight(_ id: UUID) -> Bool { id == selectedID || id == hovered || id == dragging }

    private func divider(hidden: Bool) -> some View {
        Rectangle()
            .fill(.primary.opacity(0.14))
            .frame(width: 1, height: 14)
            .opacity(hidden ? 0 : 1)
    }

    // MARK: - Segmento

    private func segment(_ entry: Entry) -> some View {
        let id = entry.item.id
        let isActive = id == selectedID
        let isHovered = hovered == id
        let session = tabs.session(for: id)
        let showsTitle = !iconsOnly
        let url = tabs.currentURL(for: entry.item)

        return Button {
            guard !justDragged else { return }
            if isActive {
                // Como en Safari: la pestaña activa abre el campo para editar la dirección.
                if let url { commandPalette.openWithCurrentURL(url) } else { commandPalette.open() }
            } else {
                tabs.select(id, in: windowState)
            }
        } label: {
            HStack(spacing: 6) {
                leadingIcon(entry, session: session, isHovered: isHovered)
                if isActive {
                    // La cápsula de siempre: dominio y recargar.
                    Text(url.map(KurthTopBarView.shortHost) ?? tabs.title(for: entry.item))
                        .font(NookDesign.Font.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(minWidth: KurthTopBarView.addressMinWidth - 2 * KurthTopBarView.capsuleInset - 2 * (NookDesign.Size.favicon + 6))
                    reloadButton
                } else if showsTitle {
                    Text(tabs.title(for: entry.item))
                        .font(NookDesign.Font.bodyRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: Self.titleMaxWidth)
                }
            }
            .padding(.horizontal, KurthTopBarView.capsuleInset)
            .frame(height: Self.segmentHeight)
            .background {
                if isHovered && !isActive {
                    Capsule().fill(.primary.opacity(0.05))
                }
            }
            .contentShape(Capsule())
            // Fuente del resalte: el fondo de la tira toma el marco del segmento seleccionado.
            .matchedGeometryEffect(id: id, in: strip, isSource: true)
        }
        .buttonStyle(.plain)
        .opacity(!isActive && (session?.isUnloaded ?? true) ? NookDesign.Surface.unloadedOpacity : 1)
        .onHoverTracking { inside in
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
        .contextMenu {
            if let url {
                Button("Copiar URL", systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Button("Cerrar pestaña", systemImage: "xmark", role: .destructive) {
                tabs.close(id)
            }
        }
        .help(tabs.title(for: entry.item))
    }

    /// El favicon, que al pasar el mouse se vuelve la X de cerrar (Safari 15 hacía lo mismo).
    @ViewBuilder
    private func leadingIcon(_ entry: Entry, session: PageSession?, isHovered: Bool) -> some View {
        ZStack {
            if isHovered {
                Button("Cerrar pestaña", systemImage: "xmark") {
                    tabs.close(entry.item.id)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .transition(.opacity)
            } else {
                ItemFavicon(item: entry.item, session: session)
                    .transition(.opacity)
            }
        }
        .frame(width: NookDesign.Size.favicon, height: NookDesign.Size.favicon)
    }

    /// Recargar o detener, sobre la página de esta ventana (inerte si otra ventana la tiene).
    private var reloadButton: some View {
        let session = tabs.controllableSession(in: windowState)
        let loading = session?.isLoading == true
        return Button(loading ? "Detener" : "Recargar", systemImage: loading ? "xmark" : "arrow.clockwise") {
            if loading { session?.stop() } else { session?.refresh() }
        }
        .kurthFieldIcon()
        .disabled(session == nil)
    }

    private var newTabButton: some View {
        Button("New Tab", systemImage: "plus") {
            commandPalette.open()
        }
        .kurthFieldIcon()
        .padding(.leading, 2)
        .help("Nueva pestaña (⌘T)")
    }

    /// Cápsula de vidrio en "capsules"; en "tinted", el mismo relleno plano que el campo vacío.
    private struct StripSurface: ViewModifier {
        let glass: Bool
        let tint: Color?

        func body(content: Content) -> some View {
            if glass {
                content.modifier(KurthGlass(tint: tint))
            } else {
                content.background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
    }
}
