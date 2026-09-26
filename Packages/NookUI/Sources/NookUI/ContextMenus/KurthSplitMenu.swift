// Licensed under GPL-3.0. See LICENSE.
//
//  KurthSplitMenu.swift
//  NookUI (rama kurth)
//
//  Las entradas de "split útil" en el menú de una pestaña (fila de la lateral, mitad del split y
//  segmento de la tira compacta): mandarla al panel derecho y "Seguir aquí los links". La lógica
//  vive en la app (Nook/Kurth/KurthSplit.swift) y llega por KurthSplitGancho; aquí solo se decide
//  qué mostrar según dónde está la pestaña.
//

import SwiftUI
import NookWeb

public struct KurthSplitMenu: View {
    let itemID: UUID

    @Environment(BrowserWindowState.self) private var windowState: BrowserWindowState?
    @Environment(TabsController.self) private var tabs

    public init(itemID: UUID) {
        self.itemID = itemID
    }

    public var body: some View {
        if let windowState {
            let gancho = KurthSplitGancho.shared
            let split = windowState.split
            let elegida = tabs.selectedItemID(in: windowState)
            if split?.rightItemID == itemID {
                // Ya es el panel derecho: solo se enciende o apaga el seguimiento.
                let sigue = gancho.sigue(itemID, en: windowState)
                Button {
                    gancho.seguir(itemID, en: windowState, !sigue)
                } label: {
                    Label(sigue ? "Dejar de seguir los links" : "Seguir aquí los links", systemImage: "arrow.turn.down.right")
                }
            } else if split?.leftItemID != itemID, elegida != itemID {
                // Fuera del split (o en él pero no como panel): al panel derecho, junto a la elegida.
                Button {
                    gancho.abrirDerecha?(itemID, windowState)
                } label: {
                    Label(split == nil ? "Abrir en el split" : "Poner en el panel derecho", systemImage: "rectangle.righthalf.filled")
                }
                Button {
                    gancho.abrirDerecha?(itemID, windowState)
                    gancho.seguir(itemID, en: windowState, true)
                } label: {
                    Label("Seguir aquí los links", systemImage: "arrow.turn.down.right")
                }
            }
        }
    }
}
