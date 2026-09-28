// Licensed under GPL-3.0. See LICENSE.
//
//  KurthChatsModelo.swift
//  Nook (rama kurth)
//
//  Lo que la lista de conversaciones (KurthChats) calcula sin tocar Nook: el título que sale del
//  primer mensaje y la hora corta de cada fila. Aparte para probarlo sin abrir la app
//  (kurth/checks/chats.sh).
//

import Foundation

enum KurthChatsModelo {
    static let sinTitulo = "Conversación nueva"
    /// Lo que cabe en la fila de la lista con el panel en su ancho mínimo (200 pt).
    static let largoDeTitulo = 42

    /// La primera línea con texto del primer mensaje de Kurth, con los espacios juntados y cortada en
    /// una palabra completa. Sin mensaje, "Conversación nueva".
    static func titulo(primerMensaje: String?) -> String {
        guard let texto = primerMensaje else { return sinTitulo }
        let linea = texto.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        guard !linea.isEmpty else { return sinTitulo }
        guard linea.count > largoDeTitulo else { return linea }
        let corte = linea.prefix(largoDeTitulo)
        let siguiente = linea[corte.endIndex]
        let aMediaPalabra = !(siguiente.isWhitespace || siguiente.isPunctuation)
        // Si el corte cae a media palabra, se regresa al último espacio (sin quedarse en nada).
        if aMediaPalabra, let espacio = corte.lastIndex(of: " "),
           corte.distance(from: corte.startIndex, to: espacio) >= largoDeTitulo / 2 {
            return String(corte[..<espacio]).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
        }
        return String(corte).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }

    /// "ahora", "12 min", "14:05" (hoy), "ayer", "jue" (esta semana) o "12 sep".
    static func horaCorta(_ fecha: Date, ahora: Date = Date(), calendario: Calendar = .current) -> String {
        let segundos = ahora.timeIntervalSince(fecha)
        if segundos < 60 { return "ahora" }
        if segundos < 3600 { return "\(Int(segundos / 60)) min" }
        let es = Locale(identifier: "es_MX")
        func formato(_ patron: String) -> String {
            let f = DateFormatter()
            f.locale = es
            f.calendar = calendario
            f.timeZone = calendario.timeZone
            f.setLocalizedDateFormatFromTemplate(patron)
            return f.string(from: fecha)
        }
        if calendario.isDate(fecha, inSameDayAs: ahora) { return formato("Hm") }
        if let ayer = calendario.date(byAdding: .day, value: -1, to: ahora), calendario.isDate(fecha, inSameDayAs: ayer) {
            return "ayer"
        }
        if segundos < 6 * 86_400 { return formato("EEE").replacingOccurrences(of: ".", with: "") }
        return formato("d MMM").replacingOccurrences(of: ".", with: "")
    }
}
