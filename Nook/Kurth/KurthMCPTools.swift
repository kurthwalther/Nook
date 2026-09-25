// Licensed under GPL-3.0. See LICENSE.
//
//  KurthMCPTools.swift
//  Nook (rama kurth)
//
//  Herramientas del MCP de desarrollo (DevMCPServer, 127.0.0.1:47823/mcp) para leer y cambiar
//  en vivo los ajustes de la capa Kurth y el tema del Space de la ventana activa, sin
//  recompilar. Kurth lo pidió el 23 sep para ajustar Nook desde el chat.
//
//  Cada ajuste nuevo de la capa se registra en `settings`: solo esas claves se pueden escribir.
//

import AppKit
import Foundation
import NookWeb

@MainActor
enum KurthMCPTools {
    struct Setting {
        let key: String
        let type: String // "bool", "number" o "string"
        let defaultValue: Any
        let info: String
    }

    static let settings: [Setting] = [
        Setting(key: "kurth.barAutoHide", type: "bool", defaultValue: false,
                info: "Barra inmersiva: escondida hasta que el mouse llega a la orilla de arriba; entonces flota sobre la página sin reservarle espacio"),
        Setting(key: "kurth.windowMaterial", type: "string", defaultValue: "sidebar",
                info: "Material del difuminado detrás de la ventana: " + KurthVibrancy.materials.keys.sorted().joined(separator: ", ")),
        Setting(key: "kurth.windowMaterialTint", type: "number", defaultValue: 1.0,
                info: "Anula cuánto del color propio del material se conserva (0–1). Normalmente NO se toca: lo calcula la opacidad del tema (\(KurthVibrancy.minTint) en el mínimo → 1 en sólido). Es lo que hace que el vidrio se vea claro sobre cualquier fondo: en 0 queda el difuminado crudo y la ventana toma la luminancia de lo de atrás. null vuelve al automático"),
        Setting(key: "kurth.pageRadius", type: "number", defaultValue: 8.0,
                info: "Radio de las esquinas de la página en pt (8 = concéntrico con la ventana de 16)"),
        Setting(key: "kurth.pageShadow", type: "number", defaultValue: 0.24,
                info: "Opacidad de la sombra de la página (0–1)"),
        Setting(key: "kurth.barStyle", type: "string", defaultValue: "capsules",
                info: "Barra de arriba: capsules (cápsulas de vidrio) o tinted (barra entera con tinte)"),
        Setting(key: "kurth.blurRadius", type: "number", defaultValue: 9.0,
                info: "Barra tinted: radio del difuminado de la página bajo la barra"),
        Setting(key: "kurth.blurSaturation", type: "number", defaultValue: 1.6,
                info: "Barra tinted: saturación del difuminado"),
        Setting(key: "kurth.tintOpacity", type: "number", defaultValue: 0.72,
                info: "Barra tinted: opacidad del color de la página sobre el difuminado"),
        Setting(key: "kurth.hairline", type: "number", defaultValue: 0.1,
                info: "Barra tinted: opacidad de la línea inferior"),
        Setting(key: "kurth.capsuleBlur", type: "bool", defaultValue: false,
                info: "Barra capsules: difuminado de la página detrás de la barra"),
        Setting(key: "kurth.capsuleTintOpacity", type: "number", defaultValue: 0.35,
                info: "Barra capsules: opacidad del color de la página dentro de las cápsulas"),
        Setting(key: "kurth.tabLayout", type: "string", defaultValue: "separate",
                info: "Pestañas: separate (solo en la barra lateral) o compact (en la barra de arriba como segmentos, Safari 15)"),
        Setting(key: "kurth.compactTabs", type: "string", defaultValue: "titles",
                info: "Con tabLayout compact: titles (ícono y título) o icons (solo ícono, como iPad)"),
        Setting(key: "kurth.colorExtension", type: "bool", defaultValue: true,
                info: "Dejar que WebKit extienda el color del borde superior de la página bajo la barra"),
        Setting(key: "kurth.scrollPocket", type: "bool", defaultValue: false,
                info: "Mostrar el scroll pocket de WebKit (el velo al hacer scroll bajo la barra)"),
        Setting(key: "kurth.passwords", type: "bool", defaultValue: true,
                info: "Llave de contraseñas de Apple en los campos de usuario y contraseña de las páginas (Touch ID → llena la página). Se aplica a las páginas que se abran después de reiniciar Nook"),
        Setting(key: "kurth.agentCardHeight", type: "number", defaultValue: 0.5,
                info: "Alto de la tarjeta del agente que se asoma con hover, como fracción del alto de la ventana (0.5 = mitad). Se limita a 360 pt como mínimo y a no tapar la barra de arriba"),
        Setting(key: "kurth.panelMaterial", type: "string", defaultValue: "glass",
                info: "Material de las cuatro barras (lateral y agente, fijas y con hover): glass (Liquid Glass; en las fijas, el fondo de la ventana pasa a vidrio) o panel (el clásico, el de antes: las fijas sin fondo propio y las flotantes con el material de la ventana)"),
        Setting(key: "kurth.agentCardPinned", type: "bool", defaultValue: false,
                info: "Tarjeta del agente fijada: se queda abierta aunque el mouse se vaya (el pin de su encabezado)"),
        Setting(key: "kurth.aiSidebarWidth", type: "number", defaultValue: 330.0,
                info: "Ancho del panel del agente en pt (200–520). Es el último que dejó el usuario al soltar el borde; cambiarlo aquí aplica a las ventanas que se abran después"),
    ]

    static let tools: [AIToolDefinition] = [
        AIToolDefinition(
            name: "kurth_get_settings",
            description: "Ajustes de la capa Kurth (valor, default, tipo y qué hace) y el tema del Space de la ventana activa.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        ),
        AIToolDefinition(
            name: "kurth_set_settings",
            description: "Cambia ajustes de la capa Kurth en vivo. values: {clave: valor}; null vuelve al default. Claves en kurth_get_settings.",
            parameters: ["type": "object", "properties": ["values": ["type": "object"]], "required": ["values"]]
        ),
        AIToolDefinition(
            name: "kurth_set_theme",
            description: "Cambia y guarda el tema del Space de la ventana activa. Campos opcionales: opacity (opacidad de la superficie sobre el difuminado, \(KurthTheme.minOpacity)–\(KurthTheme.maxOpacity)), grain (0–1), dots ([{hex, x?, y?}] hasta 3; el primero es el primario; sin x/y se ubica por su tono), harmony, kind (free, lightness, gray), lightness (0–1).",
            parameters: ["type": "object", "properties": [
                "opacity": ["type": "number"], "grain": ["type": "number"],
                "dots": ["type": "array", "items": ["type": "object"]],
                "harmony": ["type": "string"], "kind": ["type": "string"], "lightness": ["type": "number"],
            ]]
        ),
    ]

    /// nil si la herramienta no es de la capa Kurth.
    static func call(_ name: String, _ args: [String: Any], window: BrowserWindowState, tabs: TabsController) -> [String: Any]? {
        if let resultado = KurthSync.llamar(name) { return resultado }
        if let resultado = KurthPasswords.llamar(name, args) { return resultado }
        switch name {
        case "kurth_get_settings":
            return text(json(snapshot(window: window, tabs: tabs)))
        case "kurth_set_settings":
            guard let values = args["values"] as? [String: Any] else { return text("values debe ser un objeto {clave: valor}", error: true) }
            var errors: [String] = []
            for (key, value) in values {
                if let problem = set(key, value) { errors.append(problem) }
            }
            if !errors.isEmpty { return text(errors.joined(separator: "\n"), error: true) }
            return text(json(snapshot(window: window, tabs: tabs)))
        case "kurth_set_theme":
            guard !window.isIncognito, let spaceID = window.spaceID else { return text("La ventana activa no tiene un Space con tema", error: true) }
            var theme = KurthWindowTheme.theme(window: window, tabs: tabs)
            if let o = (args["opacity"] as? NSNumber)?.doubleValue { theme.opacity = min(max(o, KurthTheme.minOpacity), KurthTheme.maxOpacity) }
            if let g = (args["grain"] as? NSNumber)?.doubleValue { theme.grain = min(max(g, 0), 1) }
            if let l = (args["lightness"] as? NSNumber)?.doubleValue { theme.lightness = min(max(l, 0), 1) }
            if let k = args["kind"] as? String {
                guard let kind = KurthThemeMath.Kind(rawValue: k) else { return text("kind: free, lightness o gray", error: true) }
                theme.kind = kind
            }
            if let dots = args["dots"] as? [[String: Any]] {
                guard dots.count <= 3 else { return text("Máximo 3 colores", error: true) }
                theme.dots = dots.compactMap { d in
                    guard let hex = d["hex"] as? String else { return nil }
                    let p = KurthThemeMath.position(forHex: hex)
                    return KurthThemeDot(hex: hex, x: (d["x"] as? NSNumber)?.doubleValue ?? p.x, y: (d["y"] as? NSNumber)?.doubleValue ?? p.y)
                }
                if args["harmony"] == nil { theme.harmony = "floating" }
            }
            if let h = args["harmony"] as? String {
                guard KurthThemeMath.harmonies.contains(where: { $0.type == h }) else { return text("harmony desconocida", error: true) }
                theme.harmony = h
            }
            KurthThemeStore.shared.setTheme(theme, for: spaceID, tabs: tabs)
            return text(json(snapshot(window: window, tabs: tabs)))
        default:
            return nil
        }
    }

    private static func set(_ key: String, _ value: Any) -> String? {
        guard let setting = settings.first(where: { $0.key == key }) else { return "\(key): no es un ajuste de la capa Kurth" }
        let defaults = UserDefaults.standard
        if value is NSNull {
            if key == "kurth.pageRadius" { KurthPrefs.shared.pageRadius = setting.defaultValue as? Double ?? 8 }
            if key == "kurth.aiSidebarWidth" { KurthPrefs.shared.aiSidebarWidth = setting.defaultValue as? Double ?? 330 }
            defaults.removeObject(forKey: key)
            return nil
        }
        switch setting.type {
        case "bool":
            guard let b = value as? Bool else { return "\(key): se espera true o false" }
            defaults.set(b, forKey: key)
        case "number":
            guard let n = (value as? NSNumber)?.doubleValue else { return "\(key): se espera un número" }
            switch key {
            case "kurth.pageRadius": KurthPrefs.shared.pageRadius = n
            case "kurth.aiSidebarWidth": KurthPrefs.shared.aiSidebarWidth = n
            default: defaults.set(n, forKey: key)
            }
        default:
            guard let s = value as? String else { return "\(key): se espera texto" }
            if key == "kurth.windowMaterial", KurthVibrancy.materials[s] == nil { return "\(key): material desconocido" }
            defaults.set(s, forKey: key)
        }
        return nil
    }

    private static func snapshot(window: BrowserWindowState, tabs: TabsController) -> [String: Any] {
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        for s in settings {
            values[s.key] = ["value": defaults.object(forKey: s.key) ?? s.defaultValue, "default": s.defaultValue, "type": s.type, "info": s.info]
        }
        var result: [String: Any] = ["settings": values]
        if let spaceID = window.spaceID, !window.isIncognito,
           let data = try? JSONEncoder().encode(KurthWindowTheme.theme(window: window, tabs: tabs)),
           let theme = try? JSONSerialization.jsonObject(with: data) {
            result["theme"] = ["space": tabs.space(spaceID)?.name ?? spaceID.uuidString, "value": theme]
        }
        return result
    }

    private static func text(_ s: String, error: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": s]], "isError": error]
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
}
