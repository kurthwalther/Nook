// Licensed under GPL-3.0. See LICENSE.
//
//  KurthLaunch.swift
//  Nook (rama kurth)
//
//  Ajustes que tienen que estar antes de que exista la primera página.
//

import AppKit
import NookWeb
import WebKit

extension AppDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Enciende el muestreo de color de la parte alta de la página (_sampledPageTopColor),
        // el mismo que usa Safari para su barra. Viene apagado (0). Cada pestaña copia esta
        // configuración al crearse, así que tiene que estar antes de la primera.
        let config = BrowserConfiguration.shared.webViewConfiguration
        setPrivateDouble(config, "_setSampledPageTopColorMaxDifference:", 5)
        setPrivateDouble(config, "_setSampledPageTopColorMinHeight:", 10)
    }

    private func setPrivateDouble(_ object: NSObject, _ name: String, _ value: Double) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let imp = object.method(for: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Double) -> Void
        unsafeBitCast(imp, to: Setter.self)(object, selector, value)
    }
}
