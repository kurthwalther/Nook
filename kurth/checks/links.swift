// Licensed under GPL-3.0. See LICENSE.
//
// Prueba de KurthLinksExternosModelo sin abrir Nook: qué links web se traducen al esquema de su app
// (Zoom, Teams, Spotify, WhatsApp) y cuáles se quedan para el navegador.
// Correr con kurth/checks/links.sh. Cada comprobación imprime ✅ o ❌; termina con 1 si alguna falló.
//
// No prueba lo que necesita macOS y Nook: si la app está instalada, los universal links (Outlook) ni
// la pestaña nueva.

import Foundation

@main
struct LinksCheck {
    static var fallas = 0

    static func es(_ entrada: String, _ esperado: String?) {
        let obtenido = KurthLinksExternosModelo.traducir(URL(string: entrada)!)?.absoluteString
        if obtenido == esperado { print("✅ \(entrada)") } else {
            fallas += 1; print("❌ \(entrada)\n   esperado: \(esperado ?? "nil")\n   obtenido: \(obtenido ?? "nil")")
        }
    }

    static func main() {
        // Zoom
        es("https://zoom.us/j/81234567890?pwd=abc123", "zoommtg://zoom.us/join?action=join&confno=81234567890&pwd=abc123")
        es("https://us02web.zoom.us/j/81234567890", "zoommtg://zoom.us/join?action=join&confno=81234567890")
        es("https://zoom.us/", nil)
        es("https://zoom.us/signin", nil)
        // Teams
        es("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%7d",
           "msteams:/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%7d")
        es("https://teams.microsoft.com/v2/", nil)
        // Spotify
        es("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=x", "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        es("https://open.spotify.com/intl-es/album/1DFixLWuPkv3KT3TnV35m3", "spotify:album:1DFixLWuPkv3KT3TnV35m3")
        es("https://open.spotify.com/", nil)
        // WhatsApp
        es("https://wa.me/5219981234567?text=Hola%20Kurth", "whatsapp://send?phone=5219981234567&text=Hola%20Kurth")
        es("https://api.whatsapp.com/send?phone=5219981234567", "whatsapp://send?phone=5219981234567")
        es("https://chat.whatsapp.com/AbCdEf123", "whatsapp://chat?code=AbCdEf123")
        es("https://wa.me/message/XYZ", nil)
        // Lo demás, al navegador
        es("https://www.figma.com/design/abc/Archivo", nil)
        es("https://example.com/j/123", nil)
        es("https://krei.com.mx", nil)

        print(fallas == 0 ? "\nTodo bien." : "\n\(fallas) fallaron.")
        exit(fallas == 0 ? 0 : 1)
    }
}
