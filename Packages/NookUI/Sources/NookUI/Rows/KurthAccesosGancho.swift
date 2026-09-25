// Licensed under GPL-3.0. See LICENSE.
//
//  KurthAccesosGancho.swift
//  NookUI (rama kurth)
//
//  Ganchos para que los favoritos y los guardados sean accesos rápidos (Nook/Kurth/KurthAccesos.swift,
//  en la app): este paquete no ve el código de la app, así que ella los llena al arrancar. Sin
//  llenar, todo se comporta como upstream.
//

import NookWeb
import NookTabsCore

@MainActor
public enum KurthAccesosGancho {
    /// Al tocar un item: si es un acceso, abre (o lleva a) su pestaña y devuelve true.
    public static var abrir: ((Item, BrowserWindowState) -> Bool)?
    /// Si el acceso se ve seleccionado porque su pestaña es la elegida.
    public static var resaltado: ((UUID, UUID?) -> Bool)?

    static func estaResaltado(_ id: UUID, elegida: UUID?) -> Bool {
        elegida == id || (resaltado?(id, elegida) ?? false)
    }
}
