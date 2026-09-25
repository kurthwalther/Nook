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
//  hacerse una barra enorme"). Si no cabe, el vidrio se queda fijo al ancho disponible, con sus
//  puntas redondas y el + al final, y los segmentos se desplazan por dentro (Kurth, 24 sep: "el
//  scroll debería hacerse dentro del segmented").
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
    /// Acaba de copiar la URL: el ícono es una palomita 1.2 s.
    @State private var copiado = false
    /// Ancho del dominio de la pestaña activa en reposo; se fija mientras se ve el ícono de copiar.
    @State private var anchoDominio: CGFloat = 0
    /// Pestañas que Kurth pausó desde la tira: mientras no vuelvan a sonar, muestran play.
    @State private var pausadas: Set<UUID> = []
    /// Cuando la tira se desplaza por dentro: si está en el inicio o en el final, para el desvanecido.
    @State private var alInicio = true
    @State private var alFinal = true
    /// Arrastre para reordenar: qué segmento, cuánto se ha movido y dónde estaba cada uno al
    /// empezar (las medidas en vivo ya incluyen los desplazamientos, así que no sirven).
    @State private var dragging: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var frames: [UUID: CGRect] = [:]
    @State private var dragFrames: [UUID: CGRect] = [:]
    /// Acaba de haber un arrastre: el clic de ese mismo soltar no cuenta como selección.
    @State private var justDragged = false
    /// Ancho natural de los segmentos, del + y de la ranura que la barra le deja a la tira. La tira
    /// va como capa (overlay) sobre una ranura vacía y flexible: así la ranura mide lo que de verdad
    /// hay entre las cápsulas de los lados y nunca la empuja (medida sobre la barra, la barra crecía
    /// con la tira y siempre "cabía").
    @State private var segmentsWidth: CGFloat = 0
    @State private var plusWidth: CGFloat = 0
    @State private var slotWidth: CGFloat = 0

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
    /// Tope de la tira aunque sobre ranura: unas 7 pestañas de ancho medio (Kurth, 24 sep). Más
    /// que eso se desplaza por dentro.
    static let maxWidth: CGFloat = 7 * 120

    var body: some View {
        let available = min(slotWidth, Self.maxWidth)
        let overflows = available > 0 && segmentsWidth + plusWidth + 2 * Self.segmentInset > available
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: KurthTopBarView.capsuleHeight)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { slotWidth = $0 }
            .overlay {
                capsule(overflows: overflows, width: available)
            }
    }

    // MARK: - Cápsula

    /// El vidrio: mide su contenido mientras quepa; si no, se fija al ancho disponible y los
    /// segmentos se desplazan por dentro, con el + siempre a la vista al final.
    private func capsule(overflows: Bool, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if overflows {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        segments
                    }
                    .scrollEdgeEffectHidden(true, for: .horizontal)
                    // Desvanecido en la punta hacia la que hay más pestañas; en la que ya no hay,
                    // nada, para no apagar la primera o la última (Kurth, 25 sep).
                    .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.x <= 1 } action: { _, v in alInicio = v }
                    .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.x + $0.containerSize.width >= $0.contentSize.width - 1 } action: { _, v in alFinal = v }
                    .mask {
                        HStack(spacing: 0) {
                            LinearGradient(colors: [alInicio ? .black : .clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 30)
                            Color.black
                            LinearGradient(colors: [.black, alFinal ? .black : .clear], startPoint: .leading, endPoint: .trailing).frame(width: 30)
                        }
                    }
                    .animation(NookDesign.Motion.quick, value: alInicio)
                    .animation(NookDesign.Motion.quick, value: alFinal)
                    // La activa siempre a la vista: al cambiar de pestaña la tira se desplaza sola.
                    .onChange(of: selectedID, initial: true) { _, id in
                        guard let id else { return }
                        withAnimation(NookDesign.Motion.standard) { proxy.scrollTo(id) }
                    }
                }
            } else {
                segments
            }
            newTabButton
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plusWidth = $0 }
        }
        .padding(.horizontal, Self.segmentInset)
        .frame(width: overflows ? width : nil, height: KurthTopBarView.capsuleHeight)
        // Mide lo que mide su contenido: nada se estira para llenar la barra.
        .fixedSize(horizontal: !overflows, vertical: false)
        .clipShape(Capsule())
        .modifier(StripSurface(glass: glass, tint: tint))
        // Los ajustes de la barra también desde la tira, no solo desde sus extremos (Kurth, 24 sep).
        .contextMenu { KurthBarSettingsMenu() }
        .animation(NookDesign.Motion.standard, value: selectedID)
        .animation(NookDesign.Motion.quick, value: hovered)
        .animation(NookDesign.Motion.spring, value: dragging)
    }

    /// Los segmentos con sus separadores y el resalte de la activa, que sigue al segmento
    /// seleccionado y se desliza al cambiar. Es lo que se desplaza cuando no cabe.
    private var segments: some View {
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
                    .id(entry.id)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("strip")) } action: { frames[entry.id] = $0 }
                    .simultaneousGesture(reorderGesture(entry, in: entries))
            }
        }
        .coordinateSpace(name: "strip")
        .background(alignment: .leading) {
            if let selectedID {
                activePill.matchedGeometryEffect(id: selectedID, in: strip, isSource: false)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { segmentsWidth = $0 }
    }

    /// El segmento seleccionado de un control segmentado: relleno claro con un borde apenas.
    private var activePill: some View {
        Capsule()
            .fill(.primary.opacity(0.12))
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
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

    /// Los separadores desaparecen junto a la pestaña activa y a la que tiene el mouse encima,
    /// como en el control segmentado de Apple.
    private func touchesHighlight(_ id: UUID) -> Bool { id == selectedID || id == hovered || id == dragging }

    /// La línea ligera de Safari entre pestañas. Estaba en 0.14 y 14 pt: sobre el vidrio oscuro de una
    /// página negra no se veía y las pestañas parecían un solo bloque (Kurth, 25 sep: "necesitan una
    /// separación más notable"; en 0.3 "se pierde un poco", quedó en 0.4). Igual con solo íconos que
    /// con títulos.
    private func divider(hidden: Bool) -> some View {
        Capsule()
            .fill(.primary.opacity(0.4))
            .frame(width: 1, height: 16)
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
                // Solo ícono: sin X al pasar el mouse, o no queda por dónde entrar a la pestaña
                // (Kurth, 24 sep). Se cierra con clic derecho.
                leadingIcon(entry, session: session, isActive: isActive, showsClose: isHovered && (isActive || showsTitle))
                if isActive {
                    // La cápsula de siempre: dominio y recargar. Al pasar el mouse, copiar entra
                    // entre los dos y el dominio se corta por el principio para hacerle lugar: el
                    // ancho en reposo se mide y se fija mientras el ícono está, así la pestaña no
                    // cambia de tamaño. Un hueco reservado "se ve feo" (Kurth, 25 sep).
                    let mostrarCopiar = url != nil && (isHovered || copiado)
                    let minimo = KurthTopBarView.addressMinWidth - 2 * KurthTopBarView.capsuleInset - 2 * (NookDesign.Size.favicon + 6)
                    // El ícono mide 20 más 6 de separación: al dominio le queda el resto de su
                    // ancho de reposo y se corta por el final ("ultrajewels.co…"), sin moverse.
                    let anchoConIcono = max(anchoDominio - 26, 0)
                    HStack(spacing: 6) {
                        Text(url.map(KurthTopBarView.shortHost) ?? tabs.title(for: entry.item))
                            .font(NookDesign.Font.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: mostrarCopiar ? nil : minimo)
                            .frame(width: mostrarCopiar && anchoConIcono > 0 ? anchoConIcono : nil)
                        if mostrarCopiar, let url { copyButton(url).transition(.opacity) }
                    }
                    .frame(width: mostrarCopiar && anchoDominio > 0 ? anchoDominio : nil, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if !mostrarCopiar { anchoDominio = $0 } }
                    .animation(NookDesign.Motion.quick, value: mostrarCopiar)
                    if let session, session.hasAudioContent || session.isAudioMuted || pausadas.contains(id) { mediaButtons(session, id: id) }
                    reloadButton
                } else if showsTitle {
                    Text(tabs.title(for: entry.item))
                        .font(NookDesign.Font.bodyRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: Self.titleMaxWidth)
                }
                if !isActive, let session, session.hasAudioContent || session.isAudioMuted || pausadas.contains(id) { mediaButtons(session, id: id) }
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
            if let session, session.hasAudioContent || session.isAudioMuted {
                Button(session.isAudioMuted ? "Activar sonido" : "Silenciar pestaña",
                       systemImage: session.isAudioMuted ? "speaker.wave.2" : "speaker.slash") {
                    session.toggleMute()
                }
            }
            // Split view tenía una sola entrada, arrastrar una pestaña a la página, y Kurth no dio
            // con ella (25 sep): desde aquí, esta pestaña junto a la activa, a la derecha.
            if !isActive {
                Button("Abrir en split junto a la activa", systemImage: "rectangle.split.2x1") {
                    browserManager.enterSplit(with: id, placeOnRight: true, in: windowState)
                }
            }
            if browserManager.splitManager.isSplit(for: windowState.id) {
                Button("Separar el split", systemImage: "rectangle") {
                    browserManager.separateSplit(in: windowState)
                }
            }
            Button("Cerrar pestaña", systemImage: "xmark", role: .destructive) {
                tabs.close(id)
            }
            Divider()
            KurthBarSettingsMenu()
        }
        .help(tabs.title(for: entry.item))
    }

    /// El favicon, que al pasar el mouse se vuelve la X de cerrar (Safari 15 hacía lo mismo), y el
    /// cometa mientras la pestaña carga (solo en las que no son la activa, que lo dice en recargar).
    /// Aquí solo va estado sin acción: lo que se puede tocar (silenciar) tiene su propio lugar,
    /// speakerButton, porque este hueco ya es la X al pasar el mouse (Kurth, 25 sep).
    @ViewBuilder
    private func leadingIcon(_ entry: Entry, session: PageSession?, isActive: Bool, showsClose: Bool) -> some View {
        ZStack {
            if showsClose {
                Button("Cerrar pestaña", systemImage: "xmark") {
                    tabs.close(entry.item.id)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .transition(.opacity)
            } else if !isActive, session?.isLoading == true {
                KurthLoadingIndicator()
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else {
                ItemFavicon(item: entry.item, session: session)
                    .transition(.opacity)
            }
        }
        .frame(width: NookDesign.Size.favicon, height: NookDesign.Size.favicon)
    }

    /// Pausa/play y bocina: existen mientras la pestaña suena, está silenciada o Kurth la pausó
    /// desde aquí; al final del segmento, antes de recargar en la activa. Siempre a la vista, no al
    /// pasar el mouse, para que la pestaña no cambie de ancho al entrar y salir (Kurth, 25 sep).
    /// Pausa marca en la página qué video o audio estaba sonando y lo detiene; play reanuda
    /// exactamente esos (Nook permite reproducir desde JavaScript sin clic en la página). El estado
    /// de medios lo reporta la página sola al pausar o reanudar, así que los íconos siguen.
    private func mediaButtons(_ session: PageSession, id: UUID) -> some View {
        let suena = session.hasAudioContent
        let enPausa = !suena && pausadas.contains(id)
        return HStack(spacing: 0) {
            if suena {
                Button("Pausar", systemImage: "pause.fill") {
                    correr(en: session, id: id, """
                        document.querySelectorAll('video, audio').forEach((el) => {
                          if (!el.paused) { el.dataset.kurthPausado = '1'; el.pause(); }
                        });
                        """)
                    pausadas.insert(id)
                }
                .kurthFieldIcon()
                .help("Pausar")
            } else if enPausa {
                Button("Reanudar", systemImage: "play.fill") {
                    correr(en: session, id: id, """
                        document.querySelectorAll('video, audio').forEach((el) => {
                          if (el.dataset.kurthPausado) { delete el.dataset.kurthPausado; el.play().catch(() => {}); }
                        });
                        """)
                    pausadas.remove(id)
                }
                .kurthFieldIcon()
                .help("Reanudar")
            }
            if suena || session.isAudioMuted {
                Button(session.isAudioMuted ? "Activar sonido" : "Silenciar pestaña",
                       systemImage: session.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    session.toggleMute()
                }
                .kurthFieldIcon()
                .help(session.isAudioMuted ? "Activar sonido" : "Silenciar pestaña")
            }
        }
        .transition(.opacity)
        // Si vuelve a sonar desde la página, ya no está "pausada por Kurth".
        .onChange(of: session.hasAudioContent) { _, suena in if suena { pausadas.remove(id) } }
    }

    /// JavaScript en la página de esa pestaña, en la vista de esta ventana.
    private func correr(en session: PageSession, id: UUID, _ js: String) {
        let webView = browserManager.getWebView(for: id, in: windowState.id) ?? session.webView
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Copiar la URL de la pestaña activa: aparece al pasar el mouse por la pestaña, a la izquierda
    /// de recargar, como en Arc, y se queda mientras muestra la palomita. ⌘⇧C hace lo mismo.
    private func copyButton(_ url: URL) -> some View {
        Button("Copiar URL", systemImage: copiado ? "checkmark" : "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            withAnimation(NookDesign.Motion.quick) { copiado = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(NookDesign.Motion.quick) { copiado = false }
            }
        }
        .kurthFieldIcon()
        .help("Copiar URL (⌘⇧C)")
    }

    /// Recargar, cargando (gira) o detener (X, solo al pasar el mouse), sobre la página de esta
    /// ventana (inerte si otra ventana la tiene). El botón vive en KurthReloadButton.swift.
    private var reloadButton: some View {
        let session = tabs.controllableSession(in: windowState)
        return KurthReloadButton(session: session)
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
