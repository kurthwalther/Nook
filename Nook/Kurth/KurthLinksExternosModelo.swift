// Licensed under GPL-3.0. See LICENSE.
//
//  KurthLinksExternosModelo.swift
//  Nook (rama kurth)
//
//  La parte sin interfaz de KurthLinksExternos: traducir el link web de una app que en Mac no declara
//  universal links a su propio esquema, para abrirlo en la app en vez de en el navegador. Solo usa
//  Foundation para que kurth/checks/links.sh lo pruebe sin Nook.
//
//  Revisado en la Pro de Kurth el 26 sep (entitlements de /Applications): de sus apps solo Outlook
//  declara universal links (outlook.office.com y parecidos); Zoom, Teams, Spotify, WhatsApp y Figma no,
//  pero tienen esquema propio registrado (zoommtg, msteams, spotify, whatsapp, figma). Figma no está en
//  la tabla: su esquema no tiene formato público para abrir un archivo.
//

import Foundation

enum KurthLinksExternosModelo {

    /// El link de una app a su esquema, o nil si no es de ninguna de la tabla o no tiene la forma que
    /// la app entiende (un link a la página de inicio de Zoom no abre nada en la app: va al navegador).
    static func traducir(_ url: URL) -> URL? {
        guard let host = url.host()?.lowercased() else { return nil }
        let partes = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ n: String) -> String? { query.first { $0.name == n }?.value }

        // Zoom: zoom.us/j/<id>?pwd=… y subdominios (us02web.zoom.us). /s/ (host) y /w/ (webinar) también.
        if host == "zoom.us" || host.hasSuffix(".zoom.us"), partes.count >= 2, ["j", "s", "w"].contains(partes[0]),
           partes[1].allSatisfy(\.isNumber) {
            var c = URLComponents()
            c.scheme = "zoommtg"
            c.host = "zoom.us"
            c.path = "/join"
            c.queryItems = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: partes[1])]
                + (param("pwd").map { [URLQueryItem(name: "pwd", value: $0)] } ?? [])
            return c.url
        }

        // Teams: teams.microsoft.com/l/… (reuniones, chats, canales) → msteams:/l/…, tal cual.
        if ["teams.microsoft.com", "teams.live.com"].contains(host), partes.first == "l" {
            return URL(string: "msteams:" + url.path(percentEncoded: true) + (url.query(percentEncoded: true).map { "?" + $0 } ?? ""))
        }

        // Spotify: open.spotify.com/[intl-xx/]<tipo>/<id> → spotify:<tipo>:<id>.
        if host == "open.spotify.com" {
            let sinIdioma = partes.first?.hasPrefix("intl-") == true ? Array(partes.dropFirst()) : partes
            let tipos = ["track", "album", "playlist", "artist", "episode", "show"]
            if sinIdioma.count >= 2, tipos.contains(sinIdioma[0]), !sinIdioma[1].isEmpty {
                return URL(string: "spotify:\(sinIdioma[0]):\(sinIdioma[1])")
            }
            return nil
        }

        // WhatsApp: wa.me/<número>?text=…, api.whatsapp.com/send?phone=…, chat.whatsapp.com/<invitación>.
        if host == "wa.me", let numero = partes.first, numero.allSatisfy(\.isNumber) {
            return whatsapp("send", [("phone", numero), ("text", param("text"))])
        }
        if host == "api.whatsapp.com" || (host == "whatsapp.com" && partes.first == "send"), let numero = param("phone") {
            return whatsapp("send", [("phone", numero), ("text", param("text"))])
        }
        if host == "chat.whatsapp.com", let codigo = partes.first, !codigo.isEmpty {
            return whatsapp("chat", [("code", codigo)])
        }
        return nil
    }

    private static func whatsapp(_ accion: String, _ items: [(String, String?)]) -> URL? {
        var c = URLComponents()
        c.scheme = "whatsapp"
        c.host = accion
        c.queryItems = items.compactMap { n, v in v.map { URLQueryItem(name: n, value: $0) } }
        return c.url
    }
}
