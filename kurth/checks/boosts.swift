// Licensed under GPL-3.0. See LICENSE.
//
// Prueba de los Boosts (Nook/Kurth/KurthBoostsModelo.swift) sin abrir Nook: un WKWebView sin ventana
// con los scripts de los boosts en su controlador, páginas cargadas con loadHTMLString en hosts de
// mentira (https://boost.test, https://otro.test, http://boost.test) y un "tweak" simulado que vacía
// los scripts y repone los que llevan "// Nook", como hacen YouTube/Facebook/el bloqueador.
// Correr con kurth/checks/boosts.sh. Cada comprobación imprime ✅ o ❌; termina con 1 si alguna falló.
//
// No prueba lo que necesita Nook: la tienda (boosts.json), el MCP kurth_boost, el popover, la
// recarga de pestañas ni el envío al agente.

import AppKit
import WebKit

@main
struct BoostsCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in await Prueba().correr() }
        app.run()
    }
}

@MainActor
final class Prueba: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    var fallas = 0
    private var cargada: CheckedContinuation<Void, Never>?

    func ok(_ nombre: String, _ condicion: Bool, _ detalle: @autoclosure () -> String = "") {
        if condicion { print("✅ \(nombre)") } else { fallas += 1; print("❌ \(nombre)\n   \(detalle())") }
    }

    func js(_ codigo: String, _ args: [String: Any] = [:], en mundo: WKContentWorld) async -> Any? {
        do { return try await webView.callAsyncJavaScript(codigo, arguments: args, in: nil, contentWorld: mundo) }
        catch { return "ERROR: \((error as NSError).userInfo["WKJavaScriptExceptionMessage"] ?? error.localizedDescription)" }
    }

    func cargar(_ base: String) async {
        await withCheckedContinuation { c in
            cargada = c
            webView.loadHTMLString(Self.html, baseURL: URL(string: base))
        }
        // El JS de los boosts es async (una microtarea); un respiro para que termine.
        try? await Task.sleep(for: .milliseconds(150))
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { cargada?.resume(); cargada = nil }
    }

    /// La página ya trae su propia regla para <p> (misma especificidad que la del boost) y un script
    /// en <head> que anota si la <style> del boost ya estaba antes de que se leyera el body.
    static let html = """
    <!doctype html><html><head>
    <style>p { color: rgb(0, 0, 255); }</style>
    <script>window.estiloAlInicio = !!document.querySelector('style[data-kurth-boost]');</script>
    </head><body><p id="p">Hola</p></body></html>
    """

    func color() async -> String {
        await js("return getComputedStyle(document.getElementById('p')).color", en: .page) as? String ?? "?"
    }

    func colorEs(_ nombre: String, _ esperado: String) async {
        let c = await color()
        ok(nombre, c == esperado, "\(c) en vez de \(esperado)")
    }

    func correr() async {
        webView.navigationDelegate = self
        typealias M = KurthBoostsModelo

        // ── host ─────────────────────────────────────────────────────────────────────────
        ok("host de una URL completa", M.host(de: "https://WWW.Ejemplo.com/ruta?q=1") == "www.ejemplo.com")
        ok("host sin esquema", M.host(de: "  facebook.com ") == "facebook.com")
        ok("host con salto de línea no pasa", M.host(de: "ejem\nplo.com") == nil)
        ok("host con comillas no pasa", M.host(de: "a\"b.com") == nil)
        ok("host de URL http no lleva boost", M.host(de: URL(string: "http://boost.test/")) == nil)
        ok("host de URL https sí", M.host(de: URL(string: "https://Boost.test/x")) == "boost.test")

        // ── sintaxis ─────────────────────────────────────────────────────────────────────
        ok("JS válido pasa", M.errorDeSintaxis("document.body.dataset.x = '1';") == nil)
        ok("await permitido", M.errorDeSintaxis("await Promise.resolve(1);") == nil)
        let fuga = M.errorDeSintaxis("}).call(window); alert(1); (async function () {")
        ok("JS que se sale del envoltorio no pasa", fuga != nil, "\(fuga ?? "nil")")
        let malo = M.errorDeSintaxis("const a = 1;\nconst b = ;")
        ok("error de sintaxis con línea", malo?.contains("línea 2") == true, "\(malo ?? "nil")")

        // ── instalación ─────────────────────────────────────────────────────────────────
        let ahora = Date()
        let boosts = [
            KurthBoost(host: "boost.test", nombre: "Rojo", css: "p { color: rgb(255, 0, 0); }",
                       js: "document.body.dataset.boost = 'si'; window.variableDelBoost = 1;", encendido: true, actualizado: ahora),
            // Otro boost del mismo host no existe (host exacto), pero sí uno de otro host que truena:
            KurthBoost(host: "otro.test", nombre: "", css: "p { color: rgb(0, 128, 0); }",
                       js: "throw new Error('a propósito');", encendido: true, actualizado: ahora),
            KurthBoost(host: "apagado.test", nombre: "", css: "p { color: rgb(1, 2, 3); }", js: "",
                       encendido: false, actualizado: ahora),
        ]
        let scripts = M.scripts(boosts)
        ok("un script de CSS + uno por boost con JS encendido", scripts.count == 3, "\(scripts.count)")
        ok("todos llevan el marcador // Nook", scripts.allSatisfy { $0.source.hasPrefix("// Nook") })
        ok("el apagado no entra", !scripts.contains { $0.source.contains("apagado.test") })

        let ucc = webView.configuration.userContentController
        // Un script ajeno (como el de una extensión) que el tweak simulado no repone.
        ucc.addUserScript(WKUserScript(source: "window.ajeno = 1;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.forEach(ucc.addUserScript)
        // Tweak simulado: lee todo antes de vaciar (proxy perezoso) y repone solo los "// Nook".
        let todos = ucc.userScripts
        let propios = todos.filter { $0.source.hasPrefix("// Nook") }
        ucc.removeAllUserScripts()
        propios.forEach(ucc.addUserScript)
        ok("los boosts sobreviven al vaciado de los tweaks", ucc.userScripts.count == 3, "\(ucc.userScripts.count)")

        // ── en su host ──────────────────────────────────────────────────────────────────
        await cargar("https://boost.test/")
        await colorEs("el CSS del boost gana el empate con la página", "rgb(255, 0, 0)")
        ok("la <style> ya estaba al leer el <head> (antes de pintar)",
           await js("return window.estiloAlInicio", en: .page) as? Bool == true)
        ok("la <style> queda como último hijo de <html>",
           await js("return document.documentElement.lastElementChild.hasAttribute('data-kurth-boost')", en: .page) as? Bool == true)
        ok("el JS del boost tocó el DOM", await js("return document.body.dataset.boost", en: .page) as? String == "si")
        ok("la página no ve las variables del boost (mundo aislado)",
           await js("return typeof window.variableDelBoost", en: .page) as? String == "undefined")

        _ = await js("document.documentElement.appendChild(document.createElement('div')); await new Promise(r => setTimeout(r, 50)); return 1", en: .page)
        ok("si la página agrega algo a <html>, la <style> vuelve al final",
           await js("return document.documentElement.lastElementChild.hasAttribute('data-kurth-boost')", en: .page) as? Bool == true)

        // ── en vivo (lo que hace KurthBoosts al guardar) ────────────────────────────────
        _ = await js("return (\(M.poner))(css)", ["css": "p { color: rgb(9, 9, 9); }"], en: M.mundo)
        await colorEs("cambiar el CSS en vivo", "rgb(9, 9, 9)")
        ok("sin duplicar la <style>",
           await js("return document.querySelectorAll('style[data-kurth-boost]').length", en: .page) as? Int == 1)
        _ = await js("return (\(M.poner))(css)", ["css": ""], en: M.mundo)
        await colorEs("quitar el CSS en vivo", "rgb(0, 0, 255)")
        _ = await js("return (\(M.poner))(css)", ["css": "p { color: rgb(7, 7, 7); }"], en: M.mundo)
        await colorEs("volver a ponerlo tras quitarlo", "rgb(7, 7, 7)")

        // ── otro host: su CSS sí, el de boost.test no; su JS truena sin tumbar el CSS ────
        await cargar("https://otro.test/")
        await colorEs("en otro host solo su propio CSS", "rgb(0, 128, 0)")
        ok("el JS de boost.test no corre en otro host", await js("return document.body.dataset.boost ?? null", en: .page) is NSNull)

        // ── http: nada ──────────────────────────────────────────────────────────────────
        await cargar("http://boost.test/")
        await colorEs("en http no se aplica", "rgb(0, 0, 255)")
        ok("ni el JS", await js("return document.body.dataset.boost ?? null", en: .page) is NSNull)

        print(fallas == 0 ? "\nTodo bien." : "\n\(fallas) falla(s).")
        exit(fallas == 0 ? 0 : 1)
    }
}
