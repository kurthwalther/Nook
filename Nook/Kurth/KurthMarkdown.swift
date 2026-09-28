// Licensed under GPL-3.0. See LICENSE.
//
//  KurthMarkdown.swift
//  Nook (rama kurth)
//
//  Markdown para las respuestas del agente en el panel. Antes salían crudas ("**Tamaño:**").
//  SwiftUI solo interpreta markdown en línea (negritas, itálicas, código, tachado, enlaces); los
//  bloques (viñetas, listas numeradas, títulos, citas, código, separadores y tablas) se arman aquí
//  línea por línea. Aguanta texto a medias mientras llega: un "**" sin cerrar se queda como texto, y
//  una tabla es texto hasta que llega su fila de guiones (KurthMarkdownTablas).
//

import AppKit
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
        case tabla(KurthMarkdownTablas.Tabla)
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
        case .tabla(let t):
            KurthTablaVista(tabla: t, tamaño: tamaño, celda: enLinea)
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
    func enLinea(_ s: String) -> Text {
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
        var tabla: [String] = []

        func cerrarParrafo() {
            if !parrafo.isEmpty { salida.append(.parrafo(parrafo.joined(separator: "\n"))); parrafo = [] }
        }

        // Las filas con «|» seguidas se juntan; si la segunda es la de guiones es tabla, si no, texto.
        func cerrarTabla() {
            guard !tabla.isEmpty else { return }
            if let t = KurthMarkdownTablas.tabla(tabla) { salida.append(.tabla(t)) } else { parrafo.append(contentsOf: tabla) }
            tabla = []
        }

        for linea in texto.components(separatedBy: "\n") {
            let limpia = linea.trimmingCharacters(in: .whitespaces)
            if codigo == nil, KurthMarkdownTablas.esFila(limpia) {
                if tabla.isEmpty { cerrarParrafo() }
                tabla.append(limpia)
                continue
            }
            cerrarTabla()
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
        cerrarTabla()
        cerrarParrafo()
        return salida
    }
}

/// Una tabla del agente (KurthMarkdownTablas), plana como el bloque de código: sin líneas entre
/// filas; el encabezado en semibold y secundario. Las celdas parten renglones para caber en el panel,
/// pero nunca a media palabra: cada columna mide al menos su palabra más larga (a 206 pt salía
/// "búsqued-as"). Si con eso no cabe, la tabla se desliza de lado.
struct KurthTablaVista: View {
    let tabla: KurthMarkdownTablas.Tabla
    let tamaño: CGFloat
    let celda: (String) -> Text

    @State private var disponible: CGFloat = 0

    private let espacio: CGFloat = 12
    private let margen: CGFloat = 10

    var body: some View {
        let minimos = anchosMinimos
        let total = minimos.reduce(0, +) + espacio * CGFloat(max(minimos.count - 1, 0)) + margen * 2
        Group {
            if disponible > 0, total > disponible {
                ScrollView(.horizontal, showsIndicators: false) {
                    rejilla(minimos).frame(width: total)
                }
            } else {
                rejilla(minimos)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { disponible = $0 }
    }

    private func rejilla(_ minimos: [CGFloat]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: espacio, verticalSpacing: 5) {
            GridRow {
                ForEach(Array(tabla.encabezados.enumerated()), id: \.offset) { i, texto in
                    celda(texto)
                        .font(.system(size: tamaño, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: minimos[i], alignment: Alignment(horizontal: alineacion(i), vertical: .top))
                        .gridColumnAlignment(alineacion(i))
                }
            }
            ForEach(Array(tabla.filas.enumerated()), id: \.offset) { _, fila in
                GridRow {
                    ForEach(Array(fila.enumerated()), id: \.offset) { i, texto in
                        celda(texto)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minWidth: minimos[i], alignment: Alignment(horizontal: alineacion(i), vertical: .top))
                    }
                }
            }
        }
        .padding(.horizontal, margen)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func alineacion(_ i: Int) -> HorizontalAlignment {
        switch tabla.alineaciones[i] {
        case .izquierda: .leading
        case .centro: .center
        case .derecha: .trailing
        }
    }

    /// Por columna, lo que mide su palabra más larga (en semibold, que es lo más ancho que puede
    /// salir: el encabezado y las **negritas**), sin las marcas de markdown ni la dirección de los links.
    private var anchosMinimos: [CGFloat] {
        let fuente = NSFont.systemFont(ofSize: tamaño, weight: .semibold)
        func palabraMasLarga(_ s: String) -> CGFloat {
            let visible = s
                .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
            return visible.split(whereSeparator: \.isWhitespace)
                .map { (String($0) as NSString).size(withAttributes: [.font: fuente]).width }
                .max() ?? 0
        }
        return tabla.encabezados.indices.map { i in
            ceil(([tabla.encabezados[i]] + tabla.filas.map { $0[i] }).map(palabraMasLarga).max() ?? 0) + 1
        }
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
