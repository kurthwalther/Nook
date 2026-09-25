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
            enLinea(s).modifier(SinSeleccionSiHayEnlace(activo: Self.tieneEnlace(s)))
        case .titulo(let s):
            enLinea(s).font(.system(size: tamaño + 1, weight: .semibold))
        case .viñeta(let s, let sangria):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").font(.system(size: tamaño, weight: .regular)).foregroundStyle(.secondary)
                enLinea(s).modifier(SinSeleccionSiHayEnlace(activo: Self.tieneEnlace(s)))
            }
            .padding(.leading, CGFloat(sangria) * 12)
        case .numerada(let s, let numero, let sangria):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(numero).font(.system(size: tamaño, weight: .regular).monospacedDigit()).foregroundStyle(.secondary)
                enLinea(s).modifier(SinSeleccionSiHayEnlace(activo: Self.tieneEnlace(s)))
            }
            .padding(.leading, CGFloat(sangria) * 12)
        case .cita(let s):
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(Color.primary.opacity(0.2)).frame(width: 2)
                enLinea(s).foregroundStyle(.secondary).modifier(SinSeleccionSiHayEnlace(activo: Self.tieneEnlace(s)))
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

    private static let opciones = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)

    /// Si la línea trae algún [enlace](url), incluidas las marcas kurth-marca:ID.
    private static func tieneEnlace(_ s: String) -> Bool {
        guard s.contains("](") else { return false }
        let atribuido = (try? AttributedString(markdown: s, options: opciones)) ?? AttributedString(s)
        return atribuido.runs.contains { $0.link != nil }
    }

    /// Negritas, itálicas, `código`, ~~tachado~~ y [enlaces](url) dentro de una línea.
    private func enLinea(_ s: String) -> Text {
        let opciones = Self.opciones
        var atribuido = (try? AttributedString(markdown: s, options: opciones)) ?? AttributedString(s)
        // Las marcas del agente ([aquí](kurth-marca:ID)) llevan 📍: son chips que llevan a la página.
        let marcas = atribuido.runs.compactMap { $0.link?.scheme == "kurth-marca" ? $0.range : nil }
        for rango in marcas.reversed() { atribuido.insert(AttributedString("📍"), at: rango.lowerBound) }
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

/// En macOS, un enlace dentro de un Text seleccionable no recibe el clic: SwiftUI lo toma como
/// inicio de selección y `openURL` nunca corre (Kurth, 24 sep: el 📍 "aquí" del agente no hacía
/// nada). Los párrafos con enlace renuncian a la selección; los demás se siguen pudiendo copiar.
private struct SinSeleccionSiHayEnlace: ViewModifier {
    let activo: Bool
    func body(content: Content) -> some View {
        if activo { content.textSelection(.disabled) } else { content }
    }
}
