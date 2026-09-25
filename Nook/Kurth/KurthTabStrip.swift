// Licensed under GPL-3.0. See LICENSE.
//
//  KurthTabStrip.swift
//  Nook (rama kurth)
//
//  Pestañas compactas como las de Safari 15 (macOS Monterey): las pestañas del Space viven en la
//  misma cápsula que la dirección, como segmentos de un control segmentado. La activa muestra el
//  dominio y recargar; las demás, ícono y título, que se encogen a solo ícono cuando no caben o
//  cuando Kurth lo pide (kurth.compactTabs = icons, como en iPad). Los favoritos van siempre como
//  ícono, igual que las fijadas de Safari.
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

    private var tabs: TabsController { browserManager.tabs }
    private var selectedID: UUID? { tabs.selectedItemID(in: windowState) }

    /// Un segmento por pestaña: favoritos primero (solo ícono) y luego lo que muestra la barra
    /// lateral, en su orden, sin carpetas.
    private struct Entry: Identifiable {
        let item: Item
        let iconOnly: Bool
        var id: UUID { item.id }
    }

    private var entries: [Entry] {
        guard let spaceID = windowState.spaceID else { return [] }
        let favorites = tabs.favorites(of: spaceID).map { Entry(item: $0, iconOnly: true) }
        let rows = tabs.rows(space: spaceID).filter { !$0.item.isFolder }.map { Entry(item: $0.item, iconOnly: false) }
        return favorites + rows
    }

    /// Alto del resalte de la pestaña activa: la cápsula (28) menos 3 pt por lado.
    static let segmentHeight: CGFloat = KurthTopBarView.capsuleHeight - 6
    static let segmentInset: CGFloat = 3

    var body: some View {
        let entries = entries
        HStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    divider(hidden: touchesHighlight(entries[index - 1].id) || touchesHighlight(entry.id))
                }
                segment(entry)
            }
            newTabButton
        }
        .padding(.horizontal, Self.segmentInset)
        // El resalte de la activa sigue al segmento seleccionado y se desliza al cambiar.
        .background(alignment: .leading) {
            if let selectedID {
                Capsule()
                    .fill(.primary.opacity(0.09))
                    .matchedGeometryEffect(id: selectedID, in: strip, isSource: false)
            }
        }
        .frame(height: KurthTopBarView.capsuleHeight)
        .frame(maxWidth: .infinity)
        .clipShape(Capsule())
        .modifier(StripSurface(glass: glass, tint: tint))
        .animation(NookDesign.Motion.standard, value: selectedID)
        .animation(NookDesign.Motion.quick, value: hovered)
    }

    /// Los separadores desaparecen junto a la pestaña activa y a la que tiene el mouse encima,
    /// como en el control segmentado de Apple.
    private func touchesHighlight(_ id: UUID) -> Bool { id == selectedID || id == hovered }

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
        let showsTitle = !entry.iconOnly && !iconsOnly
        let url = tabs.currentURL(for: entry.item)

        return Button {
            if isActive {
                // Como en Safari: la pestaña activa abre el campo para editar la dirección.
                if let url { commandPalette.openWithCurrentURL(url) } else { commandPalette.open() }
            } else {
                tabs.select(id, in: windowState)
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                if isActive {
                    HStack(spacing: 6) {
                        leadingIcon(entry, session: session, isHovered: isHovered)
                        Text(url.map(KurthTopBarView.shortHost) ?? tabs.title(for: entry.item))
                            .font(NookDesign.Font.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(minWidth: 60)
                        reloadButton
                    }
                } else if showsTitle {
                    HStack(spacing: 6) {
                        leadingIcon(entry, session: session, isHovered: isHovered)
                        Text(tabs.title(for: entry.item))
                            .font(NookDesign.Font.bodyRegular)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    // Con menos de esto el título ya no dice nada: mejor solo el ícono.
                    .frame(minWidth: 72, maxWidth: .infinity)
                }
                leadingIcon(entry, session: session, isHovered: isHovered)
                    .frame(maxWidth: isActive ? nil : .infinity)
            }
            .padding(.horizontal, KurthTopBarView.capsuleInset)
            .frame(height: Self.segmentHeight)
            .frame(maxWidth: isActive ? nil : .infinity)
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
        // La activa mide lo que necesita; las demás se reparten lo que sobra.
        .fixedSize(horizontal: isActive, vertical: false)
        .layoutPriority(isActive ? 1 : 0)
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
