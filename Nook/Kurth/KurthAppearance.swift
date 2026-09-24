// Licensed under GPL-3.0. See LICENSE.
//
//  KurthAppearance.swift
//  Nook (rama kurth)
//
//  Aplica el modo de apariencia (Sistema / Claro / Oscuro) a la app.
//
//  El ajuste existía desde antes de esta rama: NookSettingsService lo guarda en
//  "settings.appearanceMode", Ajustes → Appearance lo ofrece y nuestro selector de tema también.
//  Lo que no existía era quien lo aplicara — en todo el repo no había una sola referencia a
//  NSAppearance. El valor se guardaba, el botón se pintaba como elegido, se publicaba
//  .appearanceModeChanged, y ahí terminaba todo: la ventana se quedaba con la apariencia del
//  sistema eligieras lo que eligieras. Kurth lo notó el 23 sep: puso Sistema con la Mac en
//  oscuro y Nook siguió en claro. Antes de eso me despistó a mí, que leí "dark" en el ajuste
//  guardado y di por hecho que la ventana estaba en oscuro sin mirarla.
//
//  Se aplica a NSApp: las ventanas sin apariencia propia heredan la de la app, así que con una
//  línea quedan también los menús, los paneles y las ventanas que se abran después. `nil`
//  significa seguir al sistema, y seguirlo en vivo si el Mac cambia de modo.
//
//  Medido el 23 sep con una ventana de prueba aparte: cambiar NSApp.appearance en vivo ya
//  actualiza solo el colorScheme de SwiftUI, los colores dinámicos de AppKit y el vidrio. Aun
//  así se fuerza un redibujo de cada ventana, porque Kurth ve que la barra lateral flotante a
//  veces no cambia hasta que algo más la toca. Es barato (solo ocurre al cambiar el ajuste) y
//  no depende de que la causa sea esa.
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
