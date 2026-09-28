// Licensed under GPL-3.0. See LICENSE.
//
// Prueba de KurthMarkdownTablas sin abrir Nook. Correr con kurth/checks/tablas.sh.

import Foundation

@main
struct TablasCheck {
    static var fallas = 0
    typealias T = KurthMarkdownTablas

    static func igual<V: Equatable>(_ nombre: String, _ obtenido: V, _ esperado: V) {
        if obtenido == esperado { print("✅ \(nombre)") } else {
            fallas += 1; print("❌ \(nombre)\n   esperado: \(esperado)\n   obtenido: \(obtenido)")
        }
    }

    static func main() {
        igual("celdas", T.celdas("| Hora | Esfuerzo |"), ["Hora", "Esfuerzo"])
        igual("celdas a medias", T.celdas("| 10:37 | medi"), ["10:37", "medi"])
        igual("barra escapada", T.celdas(#"| a \| b | c |"#), ["a | b", "c"])
        igual("barra en código", T.celdas("| `x | y` | z |"), ["`x | y`", "z"])
        igual("celda vacía en medio", T.celdas("| a |  | c |"), ["a", "", "c"])
        igual("alineaciones", T.alineaciones("|---|:--:|--:|:--|"), [.izquierda, .centro, .derecha, .izquierda])
        igual("no es separador", T.alineaciones("| a | b |"), nil)

        let t = T.tabla(["| Hora | Esfuerzo | Modelo |", "|---|---|--:|", "| hasta 10:37 | medium | opus |", "| 10:38 | **xhigh** |"])
        igual("encabezados", t?.encabezados, ["Hora", "Esfuerzo", "Modelo"])
        igual("alineación de la tabla", t?.alineaciones, [.izquierda, .izquierda, .derecha])
        igual("fila corta se completa", t?.filas.last, ["10:38", "**xhigh**", ""])
        igual("sin separador es texto", T.tabla(["| a | b |", "| c | d |"]), nil)
        igual("solo encabezado es texto", T.tabla(["| a | b |"]), nil)
        igual("fila larga se corta", T.tabla(["| a |", "|---|", "| 1 | 2 |"])?.filas, [["1"]])
        igual("encabezado y guiones, sin filas todavía", T.tabla(["| a | b |", "|---|---|"])?.filas, [])
        print(fallas == 0 ? "\nTodo bien." : "\n\(fallas) fallas.")
        exit(fallas == 0 ? 0 : 1)
    }
}
