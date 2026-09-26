// Licensed under GPL-3.0. See LICENSE.
//
//  KurthLinksExternos.swift
//  Nook (rama kurth)
//
//  Links que llegan de otras apps (Outlook, WhatsApp, Teams, Burbuja con `open URL`). Upstream los abre
//  todos en la ventanita flotante (ExternalMiniWindowManager). Kurth, 26 sep, cuando Nook pasó a ser su
//  navegador predeterminado: "si tengo la app, los corra en la app, si no en navegador". En orden:
//
//   1. Universal link: una app instalada declara ese dominio (en su Pro, solo Outlook). Lo decide
//      macOS con `requiresUniversalLinks`, sin lista nuestra: la app que lo declare mañana ya entra.
//   2. Apps que en Mac no declaran universal links pero tienen esquema propio (Zoom, Teams, Spotify,
//      WhatsApp): KurthLinksExternosModelo traduce el link, y solo si la app está instalada.
//   3. Pestaña nueva al frente en la ventana activa. Sin ventanas, la ventanita de upstream.
//
//  `kurth.linksExternos` = pestana (default) | ventanita (upstream tal cual). Las reglas de Air Traffic
//  Control (Space por sitio) van antes que todo esto. Los file:// de Finder siguen el camino de upstream.
//

import AppKit

@MainActor
enum KurthLinksExternos {
    static let ajuste = "kurth.linksExternos"

    /// true si el link ya se abrió (en una app o en una pestaña); false para que siga el camino de upstream.
    static func abrir(_ url: URL, _ bm: BrowserManager) async -> Bool {
        guard UserDefaults.standard.string(forKey: ajuste) != "ventanita",
              let esquema = url.scheme?.lowercased(), esquema == "http" || esquema == "https" else { return false }
        if await abrirEnApp(url) { return true }
        guard let ventana = bm.windowRegistry?.activeWindow ?? bm.windowRegistry?.windows.values.first else { return false }
        return bm.tabs.open(url: url, in: ventana, placement: .newTab) != nil
    }

    private static func abrirEnApp(_ url: URL) async -> Bool {
        let universal = NSWorkspace.OpenConfiguration()
        universal.requiresUniversalLinks = true // si ninguna app lo declara, falla en vez de volver a Nook
        if (try? await NSWorkspace.shared.open(url, configuration: universal)) != nil { return true }
        guard let enApp = KurthLinksExternosModelo.traducir(url),
              NSWorkspace.shared.urlForApplication(toOpen: enApp) != nil else { return false }
        return (try? await NSWorkspace.shared.open(enApp, configuration: NSWorkspace.OpenConfiguration())) != nil
    }
}
