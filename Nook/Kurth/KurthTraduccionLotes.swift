// Licensed under GPL-3.0. See LICENSE.
//
//  KurthTraduccionLotes.swift
//  Nook (rama kurth)
//
//  La parte pura de la traducción de páginas: convierte las unidades que entrega
//  KurthTraduccion.js en peticiones de TranslationSession y reparte las respuestas de vuelta a
//  cada nodo de texto. No sabe de WebKit ni de la app, para poder probarla sola
//  (kurth/checks/traduccion.sh la compila con respuestas falsas).
//
//  Dos rutas por unidad:
//  - Atribuida (macOS 26.4+): la frase entera como AttributedString, cada pedazo marcado con el
//    índice de su nodo. Es la buena: el modelo ve "Lee nuestra política de privacidad" completa y
//    cada tramo traducido regresa a su nodo, aunque el orden de las palabras cambie.
//  - Por partes: cada nodo por separado. Pierde contexto ("Read our" / "privacy policy" / "for
//    details." sueltos), pero nunca rompe la estructura. Se usa si la unidad es de un solo nodo, si
//    el sistema es anterior a 26.4, o si la respuesta atribuida llegó sin las marcas.
//
//  Si las marcas sobreviven la traducción no está documentado para atributos propios; por eso se
//  marca doble (atributo propio + link x-kurth-parte:N) y se mide: el estado de la pestaña cuenta
//  cuántas unidades salieron por cada ruta (kurth_translate status).
//

import Foundation
import Translation

/// Una unidad de KurthTraduccion.js: un tramo de texto corrido con sus nodos.
struct KurthUnidadDeTraduccion {
    let id: Int
    /// Núcleo de cada nodo; nil si no tiene letras (se deja como está).
    let partes: [String?]
    /// La frase completa: texto y el índice del nodo al que pertenece (-1 = espacio entre nodos).
    let segs: [(String, Int)]?

    init?(_ d: [String: Any]) {
        guard let id = (d["id"] as? NSNumber)?.intValue, let crudas = d["partes"] as? [Any] else { return nil }
        self.id = id
        partes = crudas.map { $0 as? String }
        segs = (d["segs"] as? [[Any]])?.compactMap { par in
            guard par.count == 2, let t = par[0] as? String, let i = (par[1] as? NSNumber)?.intValue else { return nil }
            return (t, i)
        }
    }

    init(id: Int, partes: [String?], segs: [(String, Int)]? = nil) {
        self.id = id; self.partes = partes; self.segs = segs
    }
}

/// Marca de cada tramo en la petición atribuida.
enum KurthParteDeTraduccion: AttributedStringKey {
    typealias Value = Int
    static let name = "KurthParteDeTraduccion"
}

enum KurthLotes {
    static let esquemaDeLink = "x-kurth-parte"

    /// Primera vuelta: atribuida para las unidades con frase (si se puede), por partes el resto.
    static func peticiones(_ unidades: [KurthUnidadDeTraduccion], atribuidas: Bool) -> [TranslationSession.Request] {
        unidades.flatMap { u -> [TranslationSession.Request] in
            if atribuidas, #available(macOS 26.4, *), let segs = u.segs, let frase = frase(segs) {
                return [TranslationSession.Request(sourceText: frase, clientIdentifier: "\(u.id)*")]
            }
            return porPartes(u)
        }
    }

    static func porPartes(_ u: KurthUnidadDeTraduccion) -> [TranslationSession.Request] {
        u.partes.enumerated().compactMap { i, p in
            guard let p, !p.isEmpty else { return nil }
            return TranslationSession.Request(sourceText: p, clientIdentifier: "\(u.id).\(i)")
        }
    }

    @available(macOS 26.4, *)
    static func frase(_ segs: [(String, Int)]) -> AttributedString? {
        var a = AttributedString()
        for (texto, i) in segs {
            var s = AttributedString(texto)
            if i >= 0 {
                s[KurthParteDeTraduccion.self] = i
                s.link = URL(string: "\(esquemaDeLink):\(i)")
            }
            a += s
        }
        return a.characters.isEmpty ? nil : a
    }

    struct Reparto {
        /// id → texto traducido de cada nodo (nil = se queda como está).
        var resultados: [Int: [String?]] = [:]
        /// Unidades atribuidas cuya respuesta no traía marcas: van a la segunda vuelta por partes.
        var sinRepartir: [KurthUnidadDeTraduccion] = []
        var atribuidas = 0
        var porPartes = 0
    }

    /// Reparte las respuestas a los nodos. `atribuidas` debe ser el mismo valor que se usó al
    /// armar las peticiones.
    static func repartir(_ unidades: [KurthUnidadDeTraduccion], _ respuestas: [TranslationSession.Response],
                         atribuidas: Bool) -> Reparto {
        var porID: [String: TranslationSession.Response] = [:]
        for r in respuestas { if let id = r.clientIdentifier { porID[id] = r } }
        var reparto = Reparto()
        for u in unidades {
            if let r = porID["\(u.id)*"] {
                if #available(macOS 26.4, *), let partes = partesAtribuidas(r.attributedTargetText, u) {
                    reparto.resultados[u.id] = partes
                    reparto.atribuidas += 1
                } else {
                    reparto.sinRepartir.append(u)
                }
                continue
            }
            var partes = [String?](repeating: nil, count: u.partes.count)
            var alguna = false
            for i in u.partes.indices where u.partes[i] != nil {
                if let t = porID["\(u.id).\(i)"]?.targetText { partes[i] = t; alguna = true }
            }
            if alguna { reparto.resultados[u.id] = partes; reparto.porPartes += 1 }
        }
        return reparto
    }

    /// Junta el texto de cada tramo marcado. Un tramo sin marca (el modelo agregó una palabra o un
    /// espacio) se pega al pedazo anterior. Sin ninguna marca, nil: la unidad va por partes.
    @available(macOS 26.4, *)
    static func partesAtribuidas(_ texto: AttributedString?, _ u: KurthUnidadDeTraduccion) -> [String?]? {
        guard let texto else { return nil }
        var partes = [String](repeating: "", count: u.partes.count)
        var alguna = false
        var anterior = 0
        for run in texto.runs {
            let pedazo = String(texto[run.range].characters)
            var indice = run[KurthParteDeTraduccion.self]
            if indice == nil, let link = run.link, link.scheme == esquemaDeLink {
                indice = Int(link.absoluteString.dropFirst(esquemaDeLink.count + 1))
            }
            if let i = indice, partes.indices.contains(i) {
                partes[i] += pedazo
                anterior = i
                alguna = true
            } else if partes.indices.contains(anterior) {
                partes[anterior] += pedazo
            }
        }
        guard alguna else { return nil }
        // Los nodos sin letras se quedan como estaban; el resto sin espacios en las orillas (JS
        // pone de vuelta el espacio original de cada nodo).
        return partes.enumerated().map { i, t in
            u.partes[i] == nil ? nil : t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Resultados en la forma que espera KurthTraduccion.js aplicar().
    static func paraJS(_ resultados: [Int: [String?]]) -> [[String: Any]] {
        resultados.map { id, partes in
            ["id": id, "partes": partes.map { $0.map { $0 as Any } ?? NSNull() }]
        }
    }
}
