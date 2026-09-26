// Licensed under GPL-3.0. See LICENSE.
//
//  KurthAgentMenciones.swift
//  Nook (rama kurth)
//
//  «@» en la caja del agente (plan del 26 sep, punto 4): escribir @ ofrece las pestañas abiertas del
//  Space de esta ventana y los Spaces; elegir una la vuelve chip, como lo señalado y lo adjuntado.
//  Al enviar:
//   · una pestaña va como resource_link (dirección y título) y, si está cargada, con su contenido en
//     markdown, igual que la pestaña activa en la primera pregunta (KurthCopilot.contenidoParaAgente);
//   · un Space va como la lista de sus pestañas en enlaces, sin contenido: leer 20 páginas para una
//     pregunta tarda y llena el contexto; si el agente necesita una, la lee con read_page.
//  La mención guarda el id de la pestaña, no su dirección: se resuelve al enviar, así que si la
//  pestaña navegó entre elegirla y mandar, va la dirección nueva.
//

import SwiftUI
import AppKit
import WebKit
import NookDesign
import NookTabsCore
import NookWeb
import NookUI

/// Algo mencionado con «@» que espera en la caja hasta el próximo mensaje.
struct KurthMencion: Identifiable, Equatable {
    enum Tipo: Equatable {
        case pestaña(UUID)
        case space(UUID)
    }
    let tipo: Tipo
    /// Lo que dice el chip. Para una pestaña, también el respaldo si se cierra antes de enviar.
    let titulo: String
    /// Respaldo de la dirección de una pestaña que se cerró antes de enviar.
    let url: URL?

    var id: String {
        switch tipo {
        case .pestaña(let id): return "pestaña-" + id.uuidString
        case .space(let id): return "space-" + id.uuidString
        }
    }
}

/// Una mención ya resuelta, lista para el mensaje: lo que dice el globo, los enlaces y el contenido.
struct KurthContextoMencionado {
    var chip: String
    var enlaces: [KurthACPResourceLink] = []
    var contenidos: [(uri: String, texto: String)] = []
}

@MainActor
@Observable
final class KurthMenciones {
    static let shared = KurthMenciones()

    /// Una sola lista para la app, como las referencias de Señalar y los adjuntos del servicio: el
    /// agente es uno por app y lo que espera en la caja también.
    private(set) var elegidas: [KurthMencion] = []

    func agregar(_ mencion: KurthMencion) {
        guard !elegidas.contains(where: { $0.id == mencion.id }) else { return }
        elegidas.append(mencion)
    }

    func quitar(_ mencion: KurthMencion) {
        elegidas.removeAll { $0.id == mencion.id }
    }

    /// Lo que va con el mensaje; la caja queda vacía.
    func tomar() -> [KurthMencion] {
        defer { elegidas.removeAll() }
        return elegidas
    }

    // MARK: - Qué se ofrece

    /// Lo que ofrece «@» con lo escrito después: primero las pestañas del Space de la ventana y
    /// luego los Spaces. Sin distinguir mayúsculas ni acentos: "@medico" encuentra "Médico".
    static func sugerencias(para consulta: String, tabs: TabsController,
                            ventana: BrowserWindowState) -> [KurthSugerencia] {
        let ya = Set(shared.elegidas.map(\.id))
        let buscar = normalizar(consulta)
        let empata: (String) -> Bool = { buscar.isEmpty || normalizar($0).contains(buscar) }

        var salida: [KurthSugerencia] = []
        if let spaceID = ventana.spaceID {
            for item in pestañasAbiertas(space: spaceID, tabs: tabs, seleccionada: tabs.selectedItemID(in: ventana)) {
                let titulo = tabs.title(for: item)
                let url = tabs.currentURL(for: item)
                let host = url.flatMap { $0.host()?.replacingOccurrences(of: "www.", with: "") } ?? ""
                guard empata(titulo) || empata(host) else { continue }
                let mencion = KurthMencion(tipo: .pestaña(item.id), titulo: titulo, url: url)
                guard !ya.contains(mencion.id) else { continue }
                salida.append(KurthSugerencia(accion: .mencion(mencion), grupo: .pestañas, titulo: titulo, detalle: host))
            }
        }
        for space in tabs.spaces(visibleIn: ventana) where empata(space.name) {
            let cuantas = pestañasDelSpace(space.id, tabs: tabs).count
            let mencion = KurthMencion(tipo: .space(space.id), titulo: space.name, url: nil)
            guard !ya.contains(mencion.id) else { continue }
            salida.append(KurthSugerencia(accion: .mencion(mencion), grupo: .spaces, titulo: "@" + space.name,
                                          detalle: cuantas == 1 ? "1 pestaña" : "\(cuantas) pestañas"))
        }
        return salida
    }

    /// Lo que se va escribiendo tras la última «@», si es la palabra que se está escribiendo al final:
    /// "compáralo con @kre" → "kre". Una @ pegada a texto ("kurth@gmail") no cuenta, para no abrir la
    /// lista en medio de un correo.
    static func consultaDeArroba(_ texto: String) -> String? {
        guard let arroba = texto.range(of: "@", options: .backwards) else { return nil }
        if let anterior = texto[..<arroba.lowerBound].last, !anterior.isWhitespace { return nil }
        let consulta = texto[arroba.upperBound...]
        guard !consulta.contains(where: \.isWhitespace) else { return nil }
        return String(consulta)
    }

    /// El texto sin la «@consulta» del final: el chip la reemplaza.
    static func sinArroba(_ texto: String) -> String {
        guard consultaDeArroba(texto) != nil, let arroba = texto.range(of: "@", options: .backwards) else { return texto }
        return String(texto[..<arroba.lowerBound])
    }

    /// Las pestañas que se ven abiertas en el Space, en el orden de la tira compacta (KurthTabStrip):
    /// favoritos y guardadas solo si tienen página cargada o son la elegida, porque en reposo son
    /// accesos y no pestañas; al final las cargadas que viven dentro de una carpeta cerrada, que
    /// `rows` no devuelve.
    static func pestañasAbiertas(space spaceID: UUID, tabs: TabsController, seleccionada: UUID?) -> [Item] {
        let abierta: (Item) -> Bool = { item in
            item.id == seleccionada || (tabs.session(for: item.id).map { !$0.isUnloaded } ?? false)
        }
        var salida = tabs.favorites(of: spaceID).filter(abierta)
        salida += tabs.rows(space: spaceID)
            .filter { !$0.item.isFolder && ($0.section != .pinned || abierta($0.item)) }
            .map(\.item)
        let vistas = Set(salida.map(\.id))
        salida += tabs.items(inSpace: spaceID).filter { !vistas.contains($0.id) && abierta($0) }
        return salida
    }

    /// Todas las pestañas de un Space, abiertas o no: favoritos, guardadas y las del día. Para «@Space»
    /// cuentan todas, porque lo que se manda son enlaces y no cuestan memoria.
    static func pestañasDelSpace(_ spaceID: UUID, tabs: TabsController) -> [Item] {
        var salida = tabs.favorites(of: spaceID)
        salida += tabs.rows(space: spaceID).filter { !$0.item.isFolder }.map(\.item)
        let vistas = Set(salida.map(\.id))
        salida += tabs.items(inSpace: spaceID).filter { !vistas.contains($0.id) }
        return salida
    }

    // MARK: - Al enviar

    /// Tope de enlaces de un Space: más no le sirve al agente para una pregunta y alarga el mensaje.
    private static let enlacesPorSpace = 60

    /// Convierte lo mencionado en enlaces y contenido. `activa`: la pestaña que ya viaja como
    /// "la que está viendo", para no mandarla dos veces. `yaConContenido`: páginas cuyo contenido
    /// el agente ya tiene en esta sesión (KurthAgentService.paginasConContenido).
    static func resolver(_ menciones: [KurthMencion], bm: BrowserManager, ventana: BrowserWindowState,
                         activa: String?, yaConContenido: Set<String>) async -> [KurthContextoMencionado] {
        let tabs = bm.tabs
        // El contenido de una sola pestaña va hasta 12 mil caracteres, como la activa; con varias se
        // reparte para que tres páginas no pesen como un libro, sin bajar de 4 mil por página.
        let conPagina = menciones.filter { if case .pestaña = $0.tipo { return true } else { return false } }.count
        let tope = max(4_000, 12_000 / max(1, conPagina))
        var ya = yaConContenido
        var salida: [KurthContextoMencionado] = []

        for mencion in menciones {
            switch mencion.tipo {
            case .pestaña(let id):
                let item = tabs.item(id)
                guard let url = item.flatMap({ tabs.currentURL(for: $0) }) ?? mencion.url else { continue }
                let titulo = item.map { tabs.title(for: $0) } ?? mencion.titulo
                var contexto = KurthContextoMencionado(chip: titulo)
                if url.absoluteString != activa {
                    contexto.enlaces = [KurthACPResourceLink(uri: url.absoluteString, name: titulo,
                                                             title: "Pestaña que el usuario mencionó con @")]
                }
                // Solo si está cargada: despertar una pestaña suspendida para leerla es cargar la
                // página entera (red, memoria) por un mensaje; el agente puede abrirla si la necesita.
                if !ya.contains(url.absoluteString), let sesion = tabs.session(for: id), !sesion.isUnloaded,
                   let webView = bm.getWebView(for: id, in: ventana.id) ?? sesion.webView,
                   let texto = await KurthCopilot.contenidoParaAgente(webView, url: sesion.url, max: tope) {
                    contexto.contenidos = [(uri: sesion.url.absoluteString, texto: texto)]
                    ya.insert(sesion.url.absoluteString)
                }
                salida.append(contexto)

            case .space(let spaceID):
                let nombre = tabs.space(spaceID)?.name ?? mencion.titulo
                let items = pestañasDelSpace(spaceID, tabs: tabs)
                let enlaces = items.prefix(enlacesPorSpace).compactMap { item -> KurthACPResourceLink? in
                    guard let url = tabs.currentURL(for: item) else { return nil }
                    return KurthACPResourceLink(uri: url.absoluteString, name: tabs.title(for: item),
                                                title: "Pestaña del Space «\(nombre)», que el usuario mencionó con @")
                }
                let chip = enlaces.count == 1 ? "\(nombre) · 1 pestaña" : "\(nombre) · \(enlaces.count) pestañas"
                salida.append(KurthContextoMencionado(chip: chip, enlaces: enlaces))
            }
        }
        return salida
    }

    private static func normalizar(_ texto: String) -> String {
        texto.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

/// El icono de una mención: el favicon de la pestaña o el punto del color del Space, como en la
/// lateral. Lo usan la lista de «@» y el chip.
struct KurthIconoDeMencion: View {
    @EnvironmentObject private var browserManager: BrowserManager
    let tipo: KurthMencion.Tipo
    var medida: CGFloat = 14

    var body: some View {
        Group {
            switch tipo {
            case .pestaña(let id):
                if let item = browserManager.tabs.item(id) {
                    ItemFavicon(item: item, session: browserManager.tabs.session(for: id))
                } else {
                    Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(Color.primary.opacity(0.5))
                }
            case .space(let id):
                Circle()
                    .fill(browserManager.tabs.space(id)?.accentColor ?? Color.primary.opacity(0.3))
                    .padding(medida * 0.2)
            }
        }
        .frame(width: medida, height: medida)
    }
}
