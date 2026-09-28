// Licensed under GPL-3.0. See LICENSE.
//
// Prueba de KurthZoom sin abrir Nook. Correr con kurth/checks/zoom.sh.

import Foundation

@main
struct ZoomCheck {
    static var fallas = 0

    static func igual(_ nombre: String, _ obtenido: Double, _ esperado: Double) {
        if abs(obtenido - esperado) < 0.0001 { print("✅ \(nombre): \(Int((obtenido * 100).rounded())) %") } else {
            fallas += 1; print("❌ \(nombre): esperado \(esperado), obtenido \(obtenido)")
        }
    }

    static func main() {
        let s = KurthZoom.siguiente
        igual("100 → +", s(1.0, true), 1.1)
        igual("100 → −", s(1.0, false), 0.9)
        igual("110 → +", s(1.1, true), 1.2)
        igual("70 → −", s(0.7, false), 0.6)
        igual("133 suelto → +", s(1.33, true), 1.4)
        igual("133 suelto → −", s(1.33, false), 1.3)
        igual("tope arriba", s(3.0, true), 3.0)
        igual("tope abajo", s(0.5, false), 0.5)
        igual("125 de antes → +", s(1.25, true), 1.3)
        igual("125 de antes → −", s(1.25, false), 1.2)
        // Veinte pasos seguidos no acumulan error de punto flotante.
        var z = 0.5
        for _ in 0..<25 { z = s(z, true) }
        igual("de 50 a 300 en 25 pasos", z, 3.0)
        igual("limitar 1.1000000000000001", KurthZoom.limitar(1.1000000000000001), 1.1)
        igual("limitar 5", KurthZoom.limitar(5), 3.0)
        print(fallas == 0 ? "\nTodo bien." : "\n\(fallas) fallas.")
        exit(fallas == 0 ? 0 : 1)
    }
}
