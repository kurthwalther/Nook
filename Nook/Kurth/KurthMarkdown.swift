// Licensed under GPL-3.0. See LICENSE.
//
//  KurthMarkdown.swift
//  Nook (rama kurth)
//
//  Markdown para las respuestas del agente en el panel. Antes salían crudas ("**Tamaño:**").
//  SwiftUI solo interpreta markdown en línea (negritas, itálicas, código, tachado, enlaces); los
//  bloques (viñetas, listas numeradas, títulos, citas, código, separadores) se arman aquí línea por
//  línea. Aguanta texto a medias mientras llega: un "**" sin cerrar se queda como texto.
//

import SwiftUI
import NookDesign

struct KurthMarkdownText: View {
    let texto: String
    var tamaño: CGFloat = 11

    private enum Bloque {
        case parrafo(String)
        case titulo(String)
        case viñeta(String, sangria: Int)
        case numerada(String, numero: String, sangria: Int)
        case cita(String)
        case codigo(String)
        case separador
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.bloques(texto).enumerated()), id: \.offset) { _, bloque in
                vista(bloque)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func vista(_ bloque: Bloque) -> some View {
        switch bloque {
        case .parrafo(let s):
            enLinea(s)
        case .titulo(let s):
            enLinea(s).font(.system(size: tamaño + 1, weight: .semibold))
        case .viñeta(let s, let sangria):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").font(.system(size: tamaño, weight: .regular)).foregroundStyle(.secondary)
                enLinea(s)
            }
            .padding(.leading, CGFloat(sangria) * 12)
        case .numerada(let s, let numero, let sangria):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(numero).font(.system(size: tamaño, weight: .regular).monospacedDigit()).foregroundStyle(.secondary)
                enLinea(s)
            }
            .padding(.leading, CGFloat(sangria) * 12)
        case .cita(let s):
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(Color.primary.opacity(0.2)).frame(width: 2)
                enLinea(s).foregroundStyle(.secondary)
            }
        case .codigo(let s):
            Text(s)
                .font(.system(size: tamaño - 1, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .separador:
            Divider()
        }
    }

    /// Negritas, itálicas, `código`, ~~tachado~~ y [enlaces](url) dentro de una línea.
    private func enLinea(_ s: String) -> Text {
        let opciones = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let atribuido = (try? AttributedString(markdown: s, options: opciones)) ?? AttributedString(s)
        return Text(atribuido).font(.system(size: tamaño, weight: .regular))
    }

    private static func bloques(_ texto: String) -> [Bloque] {
        var salida: [Bloque] = []
        var parrafo: [String] = []
        var codigo: [String]?

        func cerrarParrafo() {
            if !parrafo.isEmpty { salida.append(.parrafo(parrafo.joined(separator: "\n"))); parrafo = [] }
        }

        for linea in texto.components(separatedBy: "\n") {
            let limpia = linea.trimmingCharacters(in: .whitespaces)
            if limpia.hasPrefix("```") {
                if let abierto = codigo { salida.append(.codigo(abierto.joined(separator: "\n"))); codigo = nil }
                else { cerrarParrafo(); codigo = [] }
                continue
            }
            if codigo != nil { codigo?.append(linea); continue }
            if limpia.isEmpty { cerrarParrafo(); continue }

            let sangria = (linea.prefix { $0 == " " }.count) / 2
            if let rango = limpia.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                cerrarParrafo(); salida.append(.titulo(String(limpia[rango.upperBound...])))
            } else if limpia.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                cerrarParrafo(); salida.append(.separador)
            } else if let rango = limpia.range(of: #"^[-*•+]\s+"#, options: .regularExpression) {
                cerrarParrafo(); salida.append(.viñeta(String(limpia[rango.upperBound...]), sangria: sangria))
            } else if let rango = limpia.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                cerrarParrafo()
                let numero = String(limpia[..<rango.upperBound]).trimmingCharacters(in: .whitespaces)
                salida.append(.numerada(String(limpia[rango.upperBound...]), numero: numero, sangria: sangria))
            } else if limpia.hasPrefix(">") {
                cerrarParrafo(); salida.append(.cita(String(limpia.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                parrafo.append(linea)
            }
        }
        if let abierto = codigo { salida.append(.codigo(abierto.joined(separator: "\n"))) }
        cerrarParrafo()
        return salida
    }
}
