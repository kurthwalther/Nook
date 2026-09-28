// Licensed under GPL-3.0. See LICENSE.
//
//  KurthMarkdownTablas.swift
//  Nook (rama kurth)
//
//  Tablas de markdown (las de GitHub: filas con «|» y una fila de guiones debajo del encabezado)
//  para las respuestas del agente (KurthMarkdown). Antes llegaban como texto crudo con rayitas
//  (Kurth, 28 sep: "aquí tú puedes hacer tablas, ¿el chat de Nook también?"). Aparte y sin
//  SwiftUI para probarlo sin abrir Nook (kurth/checks/tablas.sh).
//
//  Solo cuentan las filas que empiezan con «|», que es como las escribe el agente; así una línea
//  suelta con una barra en medio no se vuelve tabla.
//

import Foundation

enum KurthMarkdownTablas {
    enum Alineacion: Equatable { case izquierda, centro, derecha }

    struct Tabla: Equatable {
        var encabezados: [String]
        var alineaciones: [Alineacion]
        var filas: [[String]]
    }

    static func esFila(_ lineaLimpia: String) -> Bool {
        lineaLimpia.hasPrefix("|")
    }

    /// Las celdas de una fila, sin las barras de las orillas y sin espacios. Una barra escapada (\|)
    /// o dentro de `código` es texto, no separador. Aguanta la fila a medias mientras llega.
    static func celdas(_ fila: String) -> [String] {
        var linea = fila.trimmingCharacters(in: .whitespaces)
        if linea.hasPrefix("|") { linea.removeFirst() }
        var resultado: [String] = []
        var actual = ""
        var enCodigo = false
        var escapado = false
        for c in linea {
            if escapado { actual.append(c); escapado = false; continue }
            switch c {
            case "\\": escapado = true
            case "`": enCodigo.toggle(); actual.append(c)
            case "|" where !enCodigo:
                resultado.append(actual.trimmingCharacters(in: .whitespaces))
                actual = ""
            default: actual.append(c)
            }
        }
        if escapado { actual.append("\\") }
        let ultima = actual.trimmingCharacters(in: .whitespaces)
        // Con la barra final, la última celda es vacía y no cuenta; sin ella (a medias), sí.
        if !ultima.isEmpty { resultado.append(ultima) }
        return resultado
    }

    /// La fila de guiones (|---|:--:|--:|) con la alineación de cada columna, o nil si no lo es.
    static func alineaciones(_ fila: String) -> [Alineacion]? {
        let partes = celdas(fila)
        guard !partes.isEmpty else { return nil }
        var salida: [Alineacion] = []
        for parte in partes {
            guard parte.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            let izquierda = parte.hasPrefix(":"), derecha = parte.hasSuffix(":")
            salida.append(izquierda && derecha ? .centro : derecha ? .derecha : .izquierda)
        }
        return salida
    }

    /// Una tabla con sus filas del mismo ancho que el encabezado (las cortas se completan, lo que
    /// sobra se corta), o nil si la segunda línea no es la de guiones: entonces es texto.
    static func tabla(_ lineas: [String]) -> Tabla? {
        guard lineas.count >= 2, let alineaciones = alineaciones(lineas[1]) else { return nil }
        let encabezados = celdas(lineas[0])
        guard !encabezados.isEmpty else { return nil }
        let n = encabezados.count
        func ajustar(_ fila: [String]) -> [String] {
            fila.count >= n ? Array(fila.prefix(n)) : fila + Array(repeating: "", count: n - fila.count)
        }
        let alineadas = alineaciones.count >= n
            ? Array(alineaciones.prefix(n))
            : alineaciones + Array(repeating: .izquierda, count: n - alineaciones.count)
        return Tabla(encabezados: encabezados, alineaciones: alineadas,
                     filas: lineas.dropFirst(2).map { ajustar(celdas($0)) })
    }
}
