// Licensed under GPL-3.0. See LICENSE.
//
//  KurthEscala.swift
//  Nook (rama kurth)
//
//  Tamaño de la barra: un solo factor que leen la barra, la tira compacta, el campo sin pestaña,
//  el indicador de carga y el encabezado del panel del agente (que copia a la barra). "Normal" es 1
//  y "Grande" 1.2 (`kurth.barScale`, clic derecho en la barra): Kurth lo pidió el 25 sep para
//  quien la vea chica; probó 1.5 ("fue mucho") y 1.25 ("lo sigo viendo grande"). Todo lo que
//  mide puntos pasa por `pt`, y lo que es letra por `fuente`.
//

import SwiftUI

enum KurthEscala {
    static let grande: CGFloat = 1.2

    /// Cualquier valor guardado arriba de 1 cuenta como "grande" (un 1.5 viejo también).
    static var factor: CGFloat {
        UserDefaults.standard.double(forKey: "kurth.barScale") > 1 ? grande : 1
    }

    /// Una medida de la barra a la escala actual, redondeada a puntos enteros.
    static func pt(_ base: CGFloat) -> CGFloat { (base * factor).rounded() }

    /// Letra del sistema a la escala actual (13 es el cuerpo de NookDesign, 11 la nota, 15 el título).
    static func fuente(_ base: CGFloat, _ peso: Font.Weight = .medium) -> Font {
        .system(size: pt(base), weight: peso)
    }
}
