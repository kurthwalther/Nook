// Licensed under GPL-3.0. See LICENSE.
//
//  KurthAccesos.swift
//  Nook (rama kurth)
//
//  Favoritos y guardados como accesos rápidos (Kurth, 25 sep): tocarlos abre su dirección en una
//  pestaña normal, arriba de las del día; ellos no se abren. Así todo lo que gasta memoria está en
//  una sola lista, a la vista (el error de Arc: un guardado abierto seguía consumiendo sin que se
//  viera abajo). Tocar de nuevo el acceso lleva a la pestaña que ya abrió, si sigue abierta.
//
//  El indicador es el resaltado de siempre: con esa pestaña elegida, el acceso de arriba y la
//  pestaña de abajo se ven seleccionados a la vez, conectados.
//
//  Qué pestaña abrió cada acceso se guarda en kurth.accesos ({acceso: pestaña}), para que la
//  conexión sobreviva al reinicio. Si la pestaña ya se cerró, el enlace no vale y se abre otra.
//

import Foundation
import NookUI
import NookWeb
import NookTabsCore

@MainActor
enum KurthAccesos {
    private static let clave = "kurth.accesos"

    private static var enlaces: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: clave) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: clave) }
    }

    /// Los ganchos de NookUI (filas de guardados) apuntan aquí.
    static func registrar(tabs: TabsController) {
        KurthAccesosGancho.abrir = { item, ventana in abrir(item, en: ventana, tabs: tabs) }
        KurthAccesosGancho.resaltado = { id, elegida in resaltado(id, elegida: elegida, tabs: tabs) }
    }

    /// Favorito o guardado (también dentro de una carpeta de Guardados).
    static func esAcceso(_ id: UUID, tabs: TabsController) -> Bool {
        switch tabs.section(of: id) {
        case .favorites, .pinned: return true
        default: return false
        }
    }

    /// La pestaña abierta desde este acceso, si sigue abierta.
    static func pestaña(de acceso: UUID, tabs: TabsController) -> UUID? {
        guard let texto = enlaces[acceso.uuidString], let id = UUID(uuidString: texto),
              let item = tabs.item(id), item.deletedAt == nil, !esAcceso(id, tabs: tabs) else { return nil }
        return id
    }

    /// Abre (o lleva a) la pestaña de un acceso. false si el item no es un acceso.
    @discardableResult
    static func abrir(_ item: Item, en ventana: BrowserWindowState, tabs: TabsController) -> Bool {
        guard !item.isFolder, esAcceso(item.id, tabs: tabs) else { return false }
        if let abierta = pestaña(de: item.id, tabs: tabs) {
            tabs.select(abierta, in: ventana)
        } else {
            guard let url = item.url ?? tabs.currentURL(for: item),
                  let nueva = tabs.open(url: url, in: ventana, placement: .newTab) else { return false }
            enlaces[item.id.uuidString] = nueva.uuidString
        }
        // De antes de esto: si el acceso tenía su propia página cargada, se suelta.
        if tabs.session(for: item.id)?.isUnloaded == false { tabs.unload(item.id) }
        return true
    }

    /// El acceso se ve seleccionado si él es el elegido o si lo es su pestaña.
    static func resaltado(_ id: UUID, elegida: UUID?, tabs: TabsController) -> Bool {
        guard let elegida else { return false }
        if elegida == id { return true }
        return enlaces[id.uuidString] == elegida.uuidString && esAcceso(id, tabs: tabs)
    }

    static func resaltado(_ id: UUID, elegida: UUID?) -> Bool {
        guard let elegida else { return false }
        return elegida == id || enlaces[id.uuidString] == elegida.uuidString
    }
}
