// Licensed under GPL-3.0. See LICENSE.
//
//  KurthZoom.swift
//  Nook (rama kurth)
//
//  El zoom como lo pidió Kurth el 28 sep: de 10 en 10 %, y un interruptor en su popup para que
//  aplique solo a la pestaña o a todo el navegador. En "todo el navegador" el nivel es uno, vive en
//  los ajustes del usuario (kurth.zoomNavegador) y resiste reinicios; cada página que navega lo toma.
//  En "esta pestaña" cada pestaña guarda el suyo y lo conserva al navegar dentro de ella (upstream lo
//  regresaba a 100 % en cada página).
//
//  Lo aplica ZoomManager (ganchos `kurth:`); aquí solo las cuentas y los ajustes guardados.
//

import Foundation

enum KurthZoom {
    static let ajusteModo = "kurth.zoomModo"          // "pestana" | "navegador"
    static let ajusteNivel = "kurth.zoomNavegador"    // el nivel de todo el navegador (1.0 = 100 %)

    static let minimo = 0.5
    static let maximo = 3.0
    static let paso = 0.1

    static var todoElNavegador: Bool {
        get { UserDefaults.standard.string(forKey: ajusteModo) == "navegador" }
        set { UserDefaults.standard.set(newValue ? "navegador" : "pestana", forKey: ajusteModo) }
    }

    static var nivelDelNavegador: Double {
        get {
            let guardado = UserDefaults.standard.double(forKey: ajusteNivel)
            return guardado > 0 ? limitar(guardado) : 1.0
        }
        set { UserDefaults.standard.set(limitar(newValue), forKey: ajusteNivel) }
    }

    /// Dentro de 50–300 % y en un décimo exacto (sin los 1.1000000000000001 de sumar 0.1).
    static func limitar(_ nivel: Double) -> Double {
        max(minimo, min(maximo, (nivel * 10).rounded() / 10))
    }

    /// El siguiente múltiplo de 10 % en esa dirección. Desde un nivel suelto (133 % de una extensión)
    /// sube a 140 y baja a 130, no a 143 ni a 123.
    static func siguiente(desde actual: Double, subiendo: Bool) -> Double {
        let pasos = actual / paso
        let n = subiendo ? (pasos + 0.01).rounded(.down) + 1 : (pasos - 0.01).rounded(.up) - 1
        return limitar(n * paso)
    }
}
