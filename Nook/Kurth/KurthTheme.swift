// Licensed under GPL-3.0. See LICENSE.
//
//  KurthTheme.swift
//  Nook (rama kurth)
//
//  Tema por Space, como Zen: de 0 a 3 colores ubicados en el lienzo del selector, armonía,
//  opacidad (0.10–0.80) y grano (0–1 en 16 pasos). Reemplaza el degradado obligatorio de Nook
//  (Surface.containerGradient) sin tocar su modelo: el tema vive en un archivo propio y el color
//  primario se escribe en SpaceRecord.accentHex, así que los puntos del switcher, carpetas,
//  Ajustes e importación de Arc siguen igual. Si el archivo se pierde, cada Space vuelve a un
//  tema de 1 color con su accentHex.
//

import Foundation
import Observation
import NookWeb

struct KurthThemeDot: Codable, Equatable {
    var hex: String
    /// Posición en el lienzo, 0…1 (centro en 0.5, 0.5).
    var x: Double
    var y: Double
}

struct KurthTheme: Codable, Equatable {
    var version = 1
    /// dots[0] es el primario.
    var dots: [KurthThemeDot] = []
    var harmony = "floating"
    var kind: KurthThemeMath.Kind = .free
    /// Luminosidad fija de los presets (kind == .lightness).
    var lightness = 0.5
    var opacity = 0.5
    var grain = 0.0

    var primaryHex: String? { dots.first?.hex }

    /// Zen usa 0.30 sobre base opaca; sobre el material translúcido el mínimo deja ver casi solo
    /// lo de atrás. Kurth lo pidió más transparente el 23 sep.
    static let minOpacity = 0.10
    static let maxOpacity = 0.80

    /// Tema de 1 color a partir del acento de siempre del Space.
    static func fromAccent(_ hex: String?) -> KurthTheme {
        guard let hex else { return KurthTheme() }
        let p = KurthThemeMath.position(forHex: hex)
        return KurthTheme(dots: [KurthThemeDot(hex: hex, x: p.x, y: p.y)])
    }

    /// Vuelve a calcular el color de cada punto desde su posición (tras mover o cambiar el tipo).
    mutating func recolor() {
        for i in dots.indices {
            dots[i].hex = KurthThemeMath.color(x: dots[i].x, y: dots[i].y, kind: kind, lightness: lightness)
        }
    }

    /// Coloca los secundarios según la armonía, a la misma distancia que el primario.
    mutating func placeCompliments() {
        guard let primary = dots.first else { return }
        let others = KurthThemeMath.compliments(primary: (primary.x, primary.y), harmony: harmony)
        dots = [primary] + others.map { KurthThemeDot(hex: primary.hex, x: $0.x, y: $0.y) }
        recolor()
    }
}

@MainActor
@Observable
final class KurthThemeStore {
    static let shared = KurthThemeStore()

    /// Temas guardados por Space.
    private(set) var saved: [UUID: KurthTheme] = [:]
    /// Vista previa mientras el selector está abierto (se guarda al cerrar, como Zen).
    private(set) var drafts: [UUID: KurthTheme] = [:]
    /// Space cuyo tema se está editando; el selector sale en la ventana que lo muestra.
    private(set) var editingSpaceID: UUID?

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.gstudios.nook/Kurth/themes.json")
    }()

    private init() { load() }

    /// El tema que se pinta. Si el acento cambió por fuera (Ajustes, importación) y ya no es el
    /// primario, el tema se reduce a 1 color con ese acento y conserva opacidad y grano.
    func theme(for spaceID: UUID?, accentHex: String?) -> KurthTheme {
        guard let spaceID else { return .fromAccent(accentHex) }
        if let draft = drafts[spaceID] { return draft }
        guard var theme = saved[spaceID] else { return .fromAccent(accentHex) }
        if let accentHex, let primary = theme.primaryHex, primary.lowercased() != accentHex.lowercased() {
            var reduced = KurthTheme.fromAccent(accentHex)
            reduced.opacity = theme.opacity
            reduced.grain = theme.grain
            theme = reduced
        }
        return theme
    }

    // MARK: - Edición

    func beginEditing(spaceID: UUID?, accentHex: String?) {
        guard let spaceID else { return }
        drafts[spaceID] = theme(for: spaceID, accentHex: accentHex)
        editingSpaceID = spaceID
    }

    func updateDraft(_ theme: KurthTheme) {
        guard let id = editingSpaceID else { return }
        drafts[id] = theme
    }

    var draft: KurthTheme? { editingSpaceID.flatMap { drafts[$0] } }

    /// Guarda al cerrar y escribe el primario en accentHex (una sola escritura, no por arrastre).
    func endEditing(tabs: TabsController?) {
        guard let id = editingSpaceID else { return }
        if let draft = drafts[id] {
            saved[id] = draft
            write()
            if let hex = draft.primaryHex { tabs?.updateSpace(id, name: nil, icon: nil, accentHex: hex) }
        }
        drafts[id] = nil
        editingSpaceID = nil
    }

    // MARK: - Archivo

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: KurthTheme].self, from: data) else { return }
        saved = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private func write() {
        let encoded = Dictionary(uniqueKeysWithValues: saved.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
