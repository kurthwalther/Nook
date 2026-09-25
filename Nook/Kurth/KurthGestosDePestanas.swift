// Licensed under GPL-3.0. See LICENSE.
//
//  KurthGestosDePestanas.swift
//  Nook (rama kurth)
//
//  Dos gestos del trackpad para moverse entre pestañas (Kurth, 25 sep):
//
//  · Deslizar con dos dedos sobre la cápsula de la dirección cambia a la pestaña de al lado, como
//    la barra de Safari en iPhone: la página se va con los dedos y la de junto entra detrás
//    (su última imagen, KurthCapturas). Al soltar pasado el 30 % del ancho, o rápido, se queda
//    la nueva; si no, regresa. En la primera o la última pestaña la página resiste y vuelve.
//  · Pellizcar la página (con el zoom en 100 %) abre la cuadrícula de pestañas siguiendo los
//    dedos (KurthCuadricula); abrir los dedos la cierra. También ⇧⌘\ y Esc.
//
//  Los dos van por monitores locales de NSEvent: el deslizar tiene que ganarle a la tira de
//  pestañas y el pellizco al zoom de WebKit, y los dos llegan como eventos, no como gestos de
//  SwiftUI. El pellizco deja pasar a WebKit el inicio y el fin del gesto para que su zoom no se
//  quede a medias; solo se queda con los cambios. Con el zoom arriba de 100 % no se toca: ahí
//  pellizcar achica la página, como siempre.
//

import AppKit
import SwiftUI
import WebKit
import NookDesign
import NookWeb
import NookUI
import NookTabsCore

@MainActor
@Observable
final class KurthGestos {
    // MARK: - Uno por ventana

    private static var porVentana: [UUID: KurthGestos] = [:]

    static func de(_ ventana: BrowserWindowState) -> KurthGestos {
        if let existente = porVentana[ventana.id] { return existente }
        let nuevo = KurthGestos()
        porVentana[ventana.id] = nuevo
        return nuevo
    }

    /// Los de la ventana activa (para el menú).
    static func activa(_ registro: WindowRegistry?) -> KurthGestos? {
        registro?.activeWindow.flatMap { porVentana[$0.id] }
    }

    // MARK: - Estado que se dibuja

    enum Lado { case izquierda, derecha }

    struct Vecina: Equatable {
        let item: Item
        let imagen: NSImage?
        let lado: Lado
        static func == (a: Vecina, b: Vecina) -> Bool { a.item.id == b.item.id && a.lado == b.lado }
    }

    /// Cuánto se ha ido la página con los dedos, en puntos (positivo: a la derecha).
    private(set) var desplazamiento: CGFloat = 0
    /// La pestaña que entra detrás mientras se desliza.
    private(set) var vecina: Vecina?
    /// La imagen de la pestaña que se acaba de elegir, encima de la página real un instante para que
    /// no se note el cambio de vista; luego se desvanece.
    private(set) var cubierta: Vecina?
    /// 0: la página; 1: la cuadrícula abierta. Entre los dos, siguiendo el pellizco.
    private(set) var progreso: CGFloat = 0

    // MARK: - Medidas (las pone la vista)

    /// Dónde se puede deslizar, en coordenadas de la ventana con el origen arriba (las de SwiftUI).
    /// La pone la barra: la cápsula de la dirección, o la tira de pestañas si todas caben.
    @ObservationIgnored var zonaDeDeslizar: CGRect?
    @ObservationIgnored var marcoDePagina: CGRect = .zero

    /// La paleta de esta ventana: con ella abierta, Esc es suyo (la cierra a ella, no a la cuadrícula).
    @ObservationIgnored weak var paleta: CommandPalette?
    @ObservationIgnored private weak var ventana: BrowserWindowState?
    @ObservationIgnored private weak var browserManager: BrowserManager?
    @ObservationIgnored private var monitores: [Any] = []

    // MARK: - Encender y apagar

    func encender(_ browserManager: BrowserManager, _ ventana: BrowserWindowState) {
        self.browserManager = browserManager
        self.ventana = ventana
        guard monitores.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.deslizar(e) ?? e }
        }) { monitores.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .magnify, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.pellizcar(e) ?? e }
        }) { monitores.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.tecla(e) ?? e }
        }) { monitores.append(m) }
    }

    func apagar() {
        monitores.forEach(NSEvent.removeMonitor)
        monitores.removeAll()
        if let id = ventana?.id { Self.porVentana[id] = nil }
    }

    // MARK: - Pestañas

    private var tabs: TabsController? { browserManager?.tabs }

    /// En el orden de la tira de arriba: favoritos y luego lo de la barra lateral, sin carpetas.
    static func pestañas(_ tabs: TabsController, espacio: UUID) -> [Item] {
        tabs.favorites(of: espacio) + tabs.rows(space: espacio).map(\.item).filter { !$0.isFolder }
    }

    private func paginaActiva() -> (id: UUID, webView: WKWebView)? {
        guard let ventana, let browserManager, let sesion = browserManager.tabs.selectedSession(in: ventana),
              let webView = browserManager.getWebView(for: sesion.itemID, in: ventana.id) ?? sesion.webView else { return nil }
        return (sesion.itemID, webView)
    }

    /// Guarda la imagen de la página que se ve (al llegar a una pestaña, al terminar de cargar y
    /// antes de un gesto, para que la próxima vez entre como está).
    func capturarActiva() {
        guard let (id, webView) = paginaActiva() else { return }
        Task { await KurthCapturas.shared.capturar(webView, id: id) }
    }

    // MARK: - Coordenadas

    private func punto(_ evento: NSEvent) -> CGPoint? {
        guard let contenido = evento.window?.contentView, evento.window === ventana?.window else { return nil }
        let p = contenido.convert(evento.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: contenido.isFlipped ? p.y : contenido.bounds.height - p.y)
    }

    // MARK: - Deslizar la cápsula

    private enum EstadoDeslizar { case libre, decidiendo, deslizando, ignorando, inercia }
    @ObservationIgnored private var estadoDeslizar = EstadoDeslizar.libre
    @ObservationIgnored private var acumulado = CGSize.zero
    @ObservationIgnored private var crudo: CGFloat = 0
    @ObservationIgnored private var anterior: Item?
    @ObservationIgnored private var siguiente: Item?
    @ObservationIgnored private var recientes: [(t: TimeInterval, dx: CGFloat)] = []

    private func deslizar(_ e: NSEvent) -> NSEvent? {
        // La rueda de un mouse no trae fases: no es un gesto de trackpad.
        if e.phase.isEmpty && e.momentumPhase.isEmpty { return e }

        // Los dedos a la derecha dan positivo, con o sin desplazamiento natural.
        let dx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        let dy = e.isDirectionInvertedFromDevice ? e.scrollingDeltaY : -e.scrollingDeltaY

        if e.phase.contains(.began) {
            guard progreso == 0, let p = punto(e), let zona = zonaDeDeslizar, zona.contains(p) else {
                estadoDeslizar = .libre
                return e
            }
            estadoDeslizar = .decidiendo
            acumulado = CGSize(width: dx, height: dy)
            return nil
        }

        switch estadoDeslizar {
        case .libre:
            return e
        case .inercia:
            // La inercia de después de soltar no debe mover nada más.
            if e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled) { estadoDeslizar = .libre }
            return e.momentumPhase.isEmpty ? e : nil
        case .ignorando:
            if terminó(e) { estadoDeslizar = .libre }
            return nil
        case .decidiendo:
            if terminó(e) { estadoDeslizar = .libre; return nil }
            acumulado.width += dx
            acumulado.height += dy
            guard abs(acumulado.width) + abs(acumulado.height) >= 6 else { return nil }
            if abs(acumulado.width) > abs(acumulado.height) {
                empezarADeslizar()
                estadoDeslizar = .deslizando
                mover(acumulado.width, t: e.timestamp)
            } else {
                estadoDeslizar = .ignorando
            }
            return nil
        case .deslizando:
            if terminó(e) {
                soltar()
                estadoDeslizar = .inercia
            } else {
                mover(dx, t: e.timestamp)
            }
            return nil
        }
    }

    private func terminó(_ e: NSEvent) -> Bool {
        e.phase.contains(.ended) || e.phase.contains(.cancelled)
    }

    private func empezarADeslizar() {
        crudo = 0
        recientes.removeAll()
        anterior = nil
        siguiente = nil
        guard let ventana, let tabs, let espacio = ventana.spaceID,
              let actual = tabs.selectedItemID(in: ventana) else { return }
        let lista = Self.pestañas(tabs, espacio: espacio)
        if let i = lista.firstIndex(where: { $0.id == actual }) {
            anterior = i > 0 ? lista[i - 1] : nil
            siguiente = i + 1 < lista.count ? lista[i + 1] : nil
        }
        // Si regresa a esta, que la encuentre como está ahora.
        capturarActiva()
    }

    private func mover(_ dx: CGFloat, t: TimeInterval) {
        crudo += dx
        recientes.append((t, dx))
        recientes.removeAll { t - $0.t > 0.1 }
        let ancho = max(marcoDePagina.width, 1)
        let hacia: Item? = crudo > 0 ? anterior : crudo < 0 ? siguiente : nil
        if let hacia {
            let lado: Lado = crudo > 0 ? .izquierda : .derecha
            if vecina?.item.id != hacia.id || vecina?.lado != lado {
                vecina = Vecina(item: hacia, imagen: KurthCapturas.shared.imagen(hacia.id), lado: lado)
            }
            desplazamiento = max(-ancho, min(ancho, crudo))
        } else {
            // En la orilla de la lista: la página resiste, como al final de un scroll.
            vecina = nil
            desplazamiento = crudo * 0.25
        }
    }

    private func soltar() {
        let ancho = max(marcoDePagina.width, 1)
        let dt = (recientes.last?.t ?? 0) - (recientes.first?.t ?? 0)
        let velocidad = dt > 0 ? recientes.reduce(0) { $0 + $1.dx } / CGFloat(dt) : 0
        let direccion: CGFloat = desplazamiento >= 0 ? 1 : -1
        let rapido = abs(velocidad) > 500 && (velocidad > 0) == (direccion > 0) && abs(desplazamiento) > 30
        guard let vecina, abs(desplazamiento) > ancho * 0.3 || rapido else {
            withAnimation(.spring(duration: 0.3, bounce: 0.12)) {
                desplazamiento = 0
            } completion: { [weak self] in
                self?.vecina = nil
            }
            return
        }
        withAnimation(.spring(duration: 0.26, bounce: 0)) {
            desplazamiento = direccion * ancho
        } completion: { [weak self] in
            guard let self, let ventana = self.ventana else { return }
            self.tabs?.select(vecina.item.id, in: ventana)
            // Sin animación: la imagen queda justo donde entra la página real.
            var sinAnimar = Transaction()
            sinAnimar.disablesAnimations = true
            withTransaction(sinAnimar) {
                self.cubierta = vecina
                self.vecina = nil
                self.desplazamiento = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.easeOut(duration: 0.18)) { self.cubierta = nil }
            }
        }
    }

    // MARK: - Pellizcar: la cuadrícula

    private enum EstadoPellizco { case libre, esperando, abriendo, cerrando, deWebKit }
    @ObservationIgnored private var estadoPellizco = EstadoPellizco.libre
    @ObservationIgnored private var pellizco: CGFloat = 0
    /// Cuánto hay que juntar los dedos para abrirla completa (la magnificación del gesto suma
    /// alrededor de −0.4 en un pellizco normal).
    private let recorrido: CGFloat = 0.4

    private func pellizcar(_ e: NSEvent) -> NSEvent? {
        guard punto(e) != nil else { return e }

        if e.phase.contains(.began) {
            pellizco = 0
            if progreso >= 1 {
                // Abierta: el gesto es nuestro de principio a fin (la página está debajo).
                estadoPellizco = .cerrando
                return nil
            }
            guard let p = punto(e), marcoDePagina.contains(p) else { estadoPellizco = .deWebKit; return e }
            estadoPellizco = .esperando
            return e
        }

        switch estadoPellizco {
        case .libre, .deWebKit:
            if terminó(e) { estadoPellizco = .libre }
            return e
        case .esperando:
            if terminó(e) { estadoPellizco = .libre; return e }
            // Juntar los dedos con la página a 100 %: es nuestro. Abrirlos, o con zoom: de WebKit.
            if e.magnification < 0, (paginaActiva()?.webView.magnification ?? 1) <= 1.001 {
                estadoPellizco = .abriendo
                capturarActiva()
                pellizco = e.magnification
                progreso = min(1, max(0, -pellizco / recorrido))
                return nil
            }
            estadoPellizco = .deWebKit
            return e
        case .abriendo:
            if terminó(e) {
                estadoPellizco = .libre
                animarCuadricula(abierta: progreso > 0.3)
                return e // WebKit vio el inicio: que vea el fin
            }
            pellizco += e.magnification
            progreso = min(1, max(0, -pellizco / recorrido))
            return nil
        case .cerrando:
            if terminó(e) {
                estadoPellizco = .libre
                animarCuadricula(abierta: progreso > 0.7)
                return nil
            }
            pellizco += e.magnification
            progreso = min(1, max(0, 1 - pellizco / recorrido))
            return nil
        }
    }

    private func animarCuadricula(abierta: Bool) {
        withAnimation(.spring(duration: 0.32, bounce: abierta ? 0.08 : 0)) { progreso = abierta ? 1 : 0 }
    }

    func alternarCuadricula() {
        if progreso < 1 { capturarActiva() }
        animarCuadricula(abierta: progreso < 1)
    }

    func abrirCuadricula() {
        capturarActiva()
        animarCuadricula(abierta: true)
    }

    func cerrarCuadricula() { animarCuadricula(abierta: false) }

    /// Desde la cuadrícula: a esa pestaña (aunque sea de otro Space) y se cierra.
    func elegir(_ id: UUID) {
        guard let ventana else { return }
        tabs?.select(id, in: ventana)
        animarCuadricula(abierta: false)
    }

    private func tecla(_ e: NSEvent) -> NSEvent? {
        // Esc cierra la cuadrícula de esta ventana.
        guard progreso > 0, e.keyCode == 53, e.window === ventana?.window, paleta?.isVisible != true else { return e }
        cerrarCuadricula()
        return nil
    }
}

// MARK: - La página que se mueve

/// Va en la página (WindowView): la mueve con el deslizar y la aleja con la cuadrícula, dibuja la
/// pestaña que entra, mide su marco y guarda la imagen de cada pestaña al verla.
struct KurthPaginaEnMovimiento: ViewModifier {
    @Environment(BrowserWindowState.self) private var ventana
    @EnvironmentObject private var browserManager: BrowserManager

    func body(content: Content) -> some View {
        let gestos = KurthGestos.de(ventana)
        let sesion = browserManager.tabs.selectedSession(in: ventana)
        content
            .offset(x: gestos.desplazamiento)
            .overlay {
                GeometryReader { geo in
                    ZStack {
                        if let vecina = gestos.vecina {
                            KurthImagenDePestaña(item: vecina.item, imagen: vecina.imagen)
                                .offset(x: gestos.desplazamiento + (vecina.lado == .izquierda ? -geo.size.width : geo.size.width))
                        }
                        if let cubierta = gestos.cubierta {
                            KurthImagenDePestaña(item: cubierta.item, imagen: cubierta.imagen)
                                .transition(.opacity)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .scaleEffect(1 - 0.08 * gestos.progreso)
            .opacity(1 - 0.5 * gestos.progreso)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { gestos.marcoDePagina = $0 }
            .onAppear { gestos.encender(browserManager, ventana) }
            .onDisappear { gestos.apagar() }
            // La imagen de cada pestaña: un momento después de llegar a ella y al terminar de cargar.
            .task(id: sesion?.itemID) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                gestos.capturarActiva()
            }
            .onChange(of: sesion?.isLoading) { _, cargando in
                guard cargando == false else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { gestos.capturarActiva() }
            }
    }
}

/// La última imagen de una pestaña a tamaño de página; sin imagen, su ícono y su título.
struct KurthImagenDePestaña: View {
    let item: Item
    let imagen: NSImage?
    @Environment(BrowserWindowState.self) private var ventana
    @EnvironmentObject private var browserManager: BrowserManager

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if let imagen {
                Image(nsImage: imagen)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
            } else {
                VStack(spacing: 10) {
                    ItemFavicon(item: item, session: browserManager.tabs.session(for: item.id))
                        .frame(width: 32, height: 32)
                    Text(browserManager.tabs.title(for: item))
                        .font(NookDesign.Font.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 24)
                }
            }
        }
        .clipShape(KurthChrome.pageShape)
    }
}

/// La cápsula de la dirección (sin pestañas compactas): ella es la zona de deslizar.
struct KurthZonaDeDeslizarAqui: ViewModifier {
    @Environment(BrowserWindowState.self) private var ventana

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { marco in
            KurthGestos.de(ventana).zonaDeDeslizar = marco
        }
    }
}

/// La cápsula (o la tira) que acepta el deslizar, medida en coordenadas de la ventana.
struct KurthZonaDeDeslizar: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}
