// Licensed under GPL-3.0. See LICENSE.
//
//  Prueba de KurthAutoconsent sin Nook: un WKWebView sin ventana, páginas locales que imitan un
//  banner de OneTrust y uno de Didomi, y el mismo KurthAutoconsent.swift que va en la app
//  (compilado con -D KURTH_CHECK, sin la parte del MCP). Correr con kurth/checks/autoconsent.sh.
//
//  Qué comprueba:
//  1. OneTrust: se pulsa "Rechazar todo" (el clic lo registra la página misma) y el banner se va.
//  2. Didomi sin botón de rechazo: el opt-out pasa por el puente eval (la API window.Didomi en el
//     mundo de la página) y la página recibe setUserDisagreeToAll().
//  3. Sitio excluido (mail.google.com): el mismo banner de OneTrust se queda intacto.
//  4. Un Didomi sin salida (ni botón de rechazo ni API): el opt-out falla, el banner queda como
//     estaba (sin ocultado previo pegado), el host queda en fallidos y al recargar ya no se toca.
//  5. La prueba propia del CMP (selfTest) corre tras el rechazo de OneTrust y pasa.
//  6. La página no ve nada de autoconsent (vive en su propio mundo).
//

import AppKit
import WebKit

@main
struct PruebaAutoconsent {
    @MainActor static var fallas = 0

    @MainActor static func verificar(_ ok: Bool, _ que: String) {
        print(ok ? "✅ \(que)" : "❌ \(que)")
        if !ok { fallas += 1 }
    }

    static let onetrust = """
    <html><body><h1>Página</h1>
    <div id="onetrust-banner-sdk" style="position:fixed;bottom:0;left:0;right:0;height:120px;background:#eee">
      Usamos cookies.
      <button id="onetrust-accept-btn-handler" onclick="window.aceptado = true; this.parentNode.style.display='none'">Aceptar</button>
      <button id="onetrust-reject-all-handler" onclick="window.rechazado = true; window.OnetrustActiveGroups = ',C0001,'; this.parentNode.style.display='none'">Rechazar todo</button>
    </div></body></html>
    """

    /// Didomi sin botón de rechazo y sin API: el único camino (eval) devuelve falso.
    static let sinSalida = """
    <html><body><h1>Página</h1>
    <div id="didomi-host"><div id="didomi-popup" style="position:fixed;inset:0;background:rgba(0,0,0,.5)">
      <div class="didomi-popup-notice">Cookies <button id="didomi-notice-agree-button" onclick="window.aceptado = true">Aceptar</button></div>
    </div></div></body></html>
    """

    static let didomi = """
    <html><body><h1>Página</h1>
    <div id="didomi-host"><div id="didomi-popup" style="position:fixed;inset:0;background:rgba(0,0,0,.5)">
      <div class="didomi-popup-notice">Cookies <button id="didomi-notice-agree-button">Aceptar</button></div>
    </div></div>
    <script>
      window.Didomi = {
        setUserDisagreeToAll() { window.didomiRechazo = true; document.getElementById('didomi-popup').style.display = 'none'; },
        getCurrentUserStatus() { return { purposes: { analytics: { enabled: !window.didomiRechazo } } }; }
      };
    </script></body></html>
    """

    @MainActor static func cargar(_ webView: WKWebView, _ html: String, _ base: String) async {
        webView.loadHTMLString(html, baseURL: URL(string: base))
        try? await Task.sleep(for: .seconds(6))
    }

    @MainActor static func js(_ webView: WKWebView, _ codigo: String) async -> Any? {
        try? await webView.evaluateJavaScript(codigo)
    }

    @MainActor static func main() async {
        let repo = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
        KurthAutoconsent.carpetaDeRecursos = repo.appendingPathComponent("Nook/Kurth/Vendor")
        UserDefaults.standard.removeObject(forKey: KurthAutoconsent.claveFallidos)
        verificar(KurthAutoconsent.fuente != nil, "script y reglas en Vendor")

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: WKWebViewConfiguration())
        KurthAutoconsent.instalar(en: webView)

        let inicio = Date()
        await cargar(webView, onetrust, "https://prueba.test/onetrust")
        verificar(await js(webView, "window.rechazado === true") as? Bool == true, "OneTrust: pulsó Rechazar todo")
        verificar(await js(webView, "window.aceptado === true") as? Bool == false, "OneTrust: no pulsó Aceptar")
        verificar(await js(webView, "getComputedStyle(document.getElementById('onetrust-banner-sdk')).display") as? String == "none",
                  "OneTrust: el banner ya no está")
        verificar(await js(webView, "typeof window.autoconsentReceiveMessage + typeof window.autoconsentSendMessage") as? String == "undefinedundefined",
                  "la página no ve autoconsent (mundo propio)")
        print("   (\(String(format: "%.1f", Date().timeIntervalSince(inicio))) s con la espera fija)")

        await cargar(webView, didomi, "https://otra.test/didomi")
        verificar(await js(webView, "window.didomiRechazo === true") as? Bool == true, "Didomi: rechazo por el puente eval (mundo de la página)")
        verificar(KurthAutoconsent.shared.eventos.contains { $0.host == "otra.test" && $0.que == "comprobado" },
                  "Didomi: la prueba propia también pasa por eval y confirma")

        await cargar(webView, onetrust, "https://mail.google.com/mail/u/0/")
        verificar(await js(webView, "window.rechazado === undefined && window.aceptado === undefined") as? Bool == true,
                  "excluido (mail.google.com): no toca nada")
        verificar(await js(webView, "getComputedStyle(document.getElementById('onetrust-banner-sdk')).display") as? String == "block",
                  "excluido: el banner sigue visible (sin ocultado previo pegado)")

        await cargar(webView, sinSalida, "https://sinsalida.test/")
        verificar(KurthAutoconsent.fallidos.contains("sinsalida.test"), "sin salida: queda en fallidos (\(KurthAutoconsent.fallidos))")
        verificar(await js(webView, "window.aceptado === undefined") as? Bool == true, "sin salida: nunca acepta")
        verificar(await js(webView, "getComputedStyle(document.getElementById('didomi-popup')).display") as? String == "block",
                  "sin salida: el banner queda visible, no escondido a medias")
        let antes = KurthAutoconsent.shared.eventos.count
        await cargar(webView, sinSalida, "https://sinsalida.test/")
        let nuevos = KurthAutoconsent.shared.eventos.dropFirst(antes).map(\.que)
        verificar(!nuevos.contains("banner"), "sin salida: al volver ya no lo intenta (\(nuevos))")
        verificar(KurthAutoconsent.shared.eventos.contains { $0.host == "prueba.test" && $0.que == "comprobado" },
                  "OneTrust: la prueba propia (selfTest) pasó")

        print("eventos:", KurthAutoconsent.shared.eventos.map { "\($0.host) \($0.cmp) \($0.que)" })
        UserDefaults.standard.removeObject(forKey: KurthAutoconsent.claveFallidos)
        print(fallas == 0 ? "todo bien" : "\(fallas) fallas")
        exit(fallas == 0 ? 0 : 1)
    }
}
