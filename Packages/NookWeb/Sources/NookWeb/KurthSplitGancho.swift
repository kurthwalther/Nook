// Licensed under GPL-3.0. See LICENSE.
//
//  KurthSplitGancho.swift
//  NookWeb (rama kurth)
//
//  Ganchos del split útil (Nook/Kurth/KurthSplit.swift, en la app): la pestaña seguidora, el ⌥-clic
//  en las filas y "abrir en el split". Este paquete y NookUI no ven el código de la app, así que
//  ella llena los closures al arrancar. Sin llenar, todo se comporta como upstream.
//
//  Estado que sí vive aquí: qué pestaña sigue los links en cada ventana. Es @Observable para que
//  las filas que pintan el indicador se redibujen solas cuando cambia.
//

import Foundation
import Observation
import NookTabsCore

@MainActor
@Observable
public final class KurthSplitGancho {
    public static let shared = KurthSplitGancho()

    /// Por ventana, la pestaña del panel derecho que carga los links del izquierdo.
    public var seguidoras: [UUID: UUID] = [:]

    /// La app: pone esa pestaña en el panel derecho (abre el split si no hay).
    @ObservationIgnored public var abrirDerecha: ((UUID, BrowserWindowState) -> Void)?
    /// La app: ⌥-clic sobre una fila. true si el split se lo quedó (la fila no debe seleccionar).
    @ObservationIgnored public var clicConOpcion: ((UUID, BrowserWindowState) -> Bool)?
    /// La app: un link activado en `session`. true si lo cargó en el panel derecho de una ventana
    /// donde esa pestaña es la izquierda y la derecha sigue.
    @ObservationIgnored public var seguirLink: ((PageSession, URL) -> Bool)?

    private init() {}

    /// Solo cuenta con el split vivo y esa pestaña en el panel derecho: al cerrar el split o
    /// cambiar el panel, se apaga sola.
    public func sigue(_ itemID: UUID, en window: BrowserWindowState) -> Bool {
        window.split?.rightItemID == itemID && seguidoras[window.id] == itemID
    }

    public func seguir(_ itemID: UUID, en window: BrowserWindowState, _ activo: Bool) {
        if activo { seguidoras[window.id] = itemID } else { seguidoras.removeValue(forKey: window.id) }
    }

    /// El split terminó o el panel derecho cambió: nadie sigue en esa ventana.
    public func olvidar(ventana windowID: UUID) {
        seguidoras.removeValue(forKey: windowID)
    }
}
