// Licensed under GPL-3.0. See LICENSE.
//
//  KurthCabezaGancho.swift
//  NookUI (rama kurth)
//
//  Qué pestaña está manejando el agente ahora (modo "con cabeza", Nook/Kurth/KurthCabeza.swift en
//  la app). Vive aquí porque la fila de la lateral (SpaceTab) está en este paquete y no ve el
//  código de la app; la app escribe, las filas leen. Es @Observable para que solo la fila que
//  cambia se vuelva a dibujar. Sin nadie que escriba, nil: todo como upstream.
//

import SwiftUI
import Observation
import NookDesign

@MainActor
@Observable
public final class KurthCabezaGancho {
    public static let shared = KurthCabezaGancho()

    /// La pestaña sobre la que el agente está actuando, o nil.
    public var controlada: UUID?

    private init() {}

    /// El anillo de la pestaña controlada: fino (1.25 pt), del color de acento del sistema y por
    /// dentro del borde, así no mueve nada. Es el mismo color del anillo de foco de macOS, que ya
    /// significa "aquí está pasando algo". Sin relleno ni velo: la pestaña se sigue leyendo igual.
    public static let anchoDelAnillo: CGFloat = 1.25
}

public extension View {
    /// Pone el anillo de "el agente está aquí" con la forma que se le dé (cápsula en la tira,
    /// rectángulo redondeado en la lateral). Entra y sale con un fundido, sin cambiar el tamaño.
    func kurthAnilloDeAgente<S: InsettableShape>(_ activo: Bool, en forma: S) -> some View {
        overlay {
            forma
                .strokeBorder(Color.accentColor, lineWidth: KurthCabezaGancho.anchoDelAnillo)
                .opacity(activo ? 1 : 0)
                .allowsHitTesting(false)
                .animation(NookDesign.Motion.standard, value: activo)
        }
    }
}
