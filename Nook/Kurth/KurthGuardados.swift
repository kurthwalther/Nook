// Licensed under GPL-3.0. See LICENSE.
//
//  KurthGuardados.swift
//  Nook (rama kurth)
//
//  Guardados como en Arc (Kurth, 24 sep): arriba de "+ New Tab" va lo que se queda (carpetas y
//  pestañas fijadas); abajo, las pestañas del día. Cerrar algo guardado lo deja en reposo y vuelve
//  a su dirección; cerrar una pestaña del día la borra. El modelo de Nook ya distinguía las dos
//  secciones, pero la de arriba no se veía mientras estaba vacía, así que "Nueva carpeta" terminaba
//  abajo y al cerrar lo de adentro se perdía (le pasó con x.com el 24 sep, 19:17).
//
//  Aquí: el estado vacío de la sección (para tener dónde soltar y dar clic derecho) y el acomodo de
//  carpetas que hayan quedado abajo. Que las carpetas nuevas o movidas vayan siempre arriba lo
//  resuelven dos ganchos en TabsController (createFolder y move).
//

import SwiftUI
import NookDesign
import NookTabsCore
import NookWeb

/// La sección de guardados sin nada: una línea tenue que dice para qué es y recibe lo que se suelta.
struct KurthGuardadosVacio: View {
    @ObservedObject private var dragSession = NookDragSessionManager.shared

    var body: some View {
        let arrastrando = dragSession.isDragging
        HStack(spacing: 6) {
            Image(systemName: "bookmark")
                .font(.system(size: 11, weight: .medium))
            // Con la barra angosta la frase larga se cortaba: se acorta sola según el ancho.
            ViewThatFits(in: .horizontal) {
                Text("Arrastra aquí lo que quieras guardar")
                Text("Arrastra aquí para guardar")
                Text("Guardar aquí")
            }
            .lineLimit(1)
        }
        .font(NookDesign.Font.secondary)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, minHeight: NookDesign.Size.row)
        .background {
            NookDesign.Radius.shape(NookDesign.Radius.md)
                .strokeBorder(style: StrokeStyle(lineWidth: NookDesign.Size.hairlineWidth, dash: [NookDesign.Spacing.sm, NookDesign.Spacing.xs]))
                .foregroundStyle(arrastrando ? NookDesign.Surface.dropBorderActive : NookDesign.Surface.dropBorderIdle)
        }
        .background {
            NookDesign.Radius.shape(NookDesign.Radius.md)
                .fill(arrastrando ? NookDesign.Surface.fillPressed : Color.clear)
        }
        .animation(NookDesign.Motion.quick, value: arrastrando)
        .help("Lo que está arriba de «New Tab» se queda: al cerrarlo descansa y vuelve a su dirección. Clic derecho para una carpeta nueva.")
    }
}

@MainActor
enum KurthGuardados {
    /// Sube a Guardados las carpetas que hayan quedado en las pestañas del día (de antes de este
    /// cambio, o llegadas de otra Mac sin él), con todo lo que llevan dentro.
    static func acomodar(tabs: TabsController) {
        for space in tabs.orderedSpaces {
            let guardados = Parent.pinned(spaceID: space.id)
            for carpeta in tabs.children(of: .tabs(spaceID: space.id)) where carpeta.isFolder {
                tabs.move(carpeta.id, to: guardados, after: tabs.children(of: guardados).last?.id)
            }
        }
    }
}
