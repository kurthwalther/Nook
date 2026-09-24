// Licensed under GPL-3.0. See LICENSE.
//
//  KurthAppearance.swift
//  Nook (rama kurth)
//
//  Aplica el modo de apariencia (Sistema / Claro / Oscuro) a la app.
//
//  El ajuste existía desde antes de esta rama: NookSettingsService lo guarda en
//  "settings.appearanceMode", Ajustes → Appearance lo ofrece y nuestro selector de tema también.
//  Upstream lo aplicaba con un preferredColorScheme por ventana en WindowView, no por app. Eso
//  tiene un defecto que se puede medir: SwiftUI no suelta la ventana cuando el valor vuelve a
//  nil. Con el Mac en oscuro: nil → negro, .light → blanco, nil otra vez → sigue blanco. Por eso
//  Kurth veía que de Claro a Sistema no pasaba nada y que en Sistema no se ponía oscuro — la
//  ventana quedaba clavada en el último modo concreto que hubiera tocado. Se quitó de WindowView
//  y el modo se aplica aquí, a NSApp.
//
//  Se aplica a NSApp: las ventanas sin apariencia propia heredan la de la app, así que con una
//  línea quedan también los menús, los paneles y las ventanas que se abran después. `nil`
//  significa seguir al sistema, y seguirlo en vivo si el Mac cambia de modo.
//
//  Medido el 23 sep con una ventana de prueba aparte: cambiar NSApp.appearance en vivo ya
//  actualiza solo el colorScheme de SwiftUI, los colores dinámicos de AppKit y el vidrio, y sí
//  revierte al volver a nil. El redibujo de refresh() se queda porque es barato y solo corre al
//  cambiar el ajuste.
//

import AppKit
import NookSettings

@MainActor
enum KurthAppearance {
    /// Al arrancar (KurthLaunch) y en cada cambio del ajuste.
    static func start() {
        apply()
        NotificationCenter.default.addObserver(forName: .appearanceModeChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply() }
        }
    }

    static func apply() {
        let stored = UserDefaults.standard.string(forKey: "settings.appearanceMode")
        let mode = stored.flatMap(AppearanceMode.init(rawValue:)) ?? .system
        NSApp.appearance = switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        refresh()
    }

    /// Empuja el cambio por las ventanas ya abiertas. `appearance = nil` las deja heredando de
    /// la app (y del sistema cuando la app también hereda), que es lo que queremos en los tres
    /// modos; lo que agrega es el redibujo de vistas que ya estaban compuestas.
    private static func refresh() {
        for window in NSApp.windows {
            window.appearance = nil
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
        }
    }
}
