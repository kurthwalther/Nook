// Licensed under GPL-3.0. See LICENSE.
//
//  Prueba de KurthJalarParaRecargar sin Nook: un WKWebView sin ventana, gestos de trackpad
//  sintéticos (eventos de scroll con fases) y el mismo KurthJalarParaRecargar.swift de la app.
//  FocusableWKWebView aquí es un doble con los dos ganchos de la app (scrollWheel y el aviso de
//  scroll de WebKit) y una sesión que cuenta recargas. Correr con kurth/checks/jalar.sh.
//
//  El estiramiento de un gesto sintético no es el de un trackpad real (aquí 70–80 pt con 1600 px de
//  jalón); por eso la distancia se baja a 24 pt con -kurth.pullToRefreshDistancia. El tacto real
//  (umbral, háptico, cómo se ve la flecha) solo se prueba con la mano.
//

import AppKit
import WebKit

final class SesionFalsa { var recargas = 0; func refresh() { recargas += 1 } }

class FocusableWKWebView: WKWebView {
    let owningSession: SesionFalsa? = SesionFalsa()
    var maximo: CGFloat = 0

    @objc(_updateScrollGeometryWithContentOffset:contentSize:)
    func avisoDeScroll(_ o: CGPoint, _ s: CGSize) {
        MainActor.assumeIsolated {
            KurthJalarParaRecargar.desplazamiento(o.y, en: self)
            maximo = max(maximo, -o.y)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        KurthJalarParaRecargar.rueda(event, en: self)
        super.scrollWheel(with: event)
    }

    var flechaVisible: Bool { subviews.contains { !$0.isHidden && "\(type(of: $0))".contains("Indicador") } }
}

@main
struct PruebaJalar {
    @MainActor static var fallas = 0
    @MainActor static func verificar(_ ok: Bool, _ que: String) {
        print(ok ? "✅ \(que)" : "❌ \(que)")
        if !ok { fallas += 1 }
    }

    static func evento(_ dy: Int32, _ fase: Int64) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: fase) // 1 began, 2 changed, 4 ended
        return NSEvent(cgEvent: cg)!
    }

    /// Dedos hacia abajo `n` veces; devuelve si la flecha se veía justo antes de soltar.
    @MainActor static func jalar(_ wv: FocusableWKWebView, _ dy: Int32, _ n: Int) async -> Bool {
        wv.maximo = 0
        wv.scrollWheel(with: evento(dy, 1))
        for _ in 0..<n {
            wv.scrollWheel(with: evento(dy, 2))
            try? await Task.sleep(for: .milliseconds(16))
        }
        let visible = wv.flechaVisible
        wv.scrollWheel(with: evento(0, 4))
        try? await Task.sleep(for: .seconds(1))
        return visible
    }

    @MainActor static func pagina(_ html: String) async -> FocusableWKWebView {
        let wv = FocusableWKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        let sel = NSSelectorFromString("_setNeedsScrollGeometryUpdates:")
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(wv.method(for: sel), to: Setter.self)(wv, sel, true)
        wv.loadHTMLString(html, baseURL: nil)
        try? await Task.sleep(for: .seconds(1.5))
        return wv
    }

    @MainActor static func main() async {
        UserDefaults.standard.set(24.0, forKey: KurthJalarParaRecargar.ajusteDistancia)
        defer { UserDefaults.standard.removeObject(forKey: KurthJalarParaRecargar.ajusteDistancia) }

        let normal = await pagina("<html><body style='margin:0'><div style='height:5000px'></div></body></html>")
        let vio = await jalar(normal, 40, 40)
        verificar(normal.maximo > 24, "WebKit reporta el estiramiento como desplazamiento negativo (\(normal.maximo) pt)")
        verificar(vio, "la flecha se ve mientras se jala")
        verificar(normal.owningSession?.recargas == 1, "jalón largo desde arriba: recarga")
        verificar(!normal.flechaVisible, "al regresar la página la flecha se va")

        _ = await jalar(normal, 3, 5)
        verificar(normal.owningSession?.recargas == 1, "jalón corto: no recarga")

        _ = try? await normal.evaluateJavaScript("scrollTo(0, 200); 1")
        try? await Task.sleep(for: .seconds(0.5))
        let vioMitad = await jalar(normal, 40, 40)
        verificar(normal.owningSession?.recargas == 1 && !vioMitad,
                  "empezar a media página y rebotar en el tope: no recarga ni muestra flecha (\(normal.maximo) pt)")

        let interno = await pagina("<html><body style='margin:0;height:100vh;overflow:hidden'><div id=d style='height:100vh;overflow:auto'><div style='height:5000px'></div></div><script>d.scrollTop=300</script></body></html>")
        _ = await jalar(interno, 40, 40)
        verificar(interno.owningSession?.recargas == 0 && interno.maximo == 0,
                  "div con scroll propio (Gmail, Zoho): WebKit no rebota la página y no recarga")

        let sinRebote = await pagina("<html style='overscroll-behavior:none'><body style='margin:0'><div style='height:5000px'></div></body></html>")
        _ = await jalar(sinRebote, 40, 40)
        verificar(sinRebote.owningSession?.recargas == 0, "overscroll-behavior: none: no recarga")

        UserDefaults.standard.set(false, forKey: KurthJalarParaRecargar.ajuste)
        let apagado = await pagina("<html><body style='margin:0'><div style='height:5000px'></div></body></html>")
        _ = await jalar(apagado, 40, 40)
        verificar(apagado.owningSession?.recargas == 0, "con kurth.pullToRefresh apagado: no recarga")
        UserDefaults.standard.removeObject(forKey: KurthJalarParaRecargar.ajuste)

        print(fallas == 0 ? "todo bien" : "\(fallas) fallas")
        exit(fallas == 0 ? 0 : 1)
    }
}
