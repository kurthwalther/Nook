// Licensed under GPL-3.0. See LICENSE.
//
//  KurthAutoconsent.swift
//  Nook (rama kurth)
//
//  Contesta solo los banners de cookies, eligiendo rechazar (opt-out), con las reglas de
//  duckduckgo/autoconsent 16.42.0 (MPL-2.0, Nook/Kurth/Vendor/Autoconsent-LICENSE.txt; es la
//  misma librería que usan los navegadores de DuckDuckGo). Los archivos de Vendor van sin tocar:
//  autoconsent.playwright.js es el script de contenido y autoconsent-compact-rules.json las reglas.
//
//  Cómo habla con Nook. El script vive en un mundo de contenido propio (KurthAutoconsent), no en
//  el de la página: la página no ve sus variables ni puede mandarle mensajes. Por el canal
//  `kurthAutoconsent` llegan:
//  - init: el script arrancó en un marco. Se le contesta initResp con la configuración y solo las
//    reglas que aplican a esa URL (el filtro de encoding.ts portado aquí), o enabled: false si el
//    ajuste está apagado, el sitio está excluido o ya falló antes ahí.
//  - eval: algunas reglas necesitan leer la API del CMP en el mundo de la página (window.Didomi,
//    __tcfapi…). Se evalúa en ese marco con callAsyncJavaScript en `.page` y se contesta evalResp.
//    callAsyncJavaScript no pasa por la CSP de la página; un eval() dentro sí pasaría.
//  - popupFound: hay banner visible. Aquí se decide y se manda optOut.
//  - optOutResult: si el CMP tiene prueba propia, se le pide (selfTest) para confirmar que el
//    rechazo quedó guardado. optOutResult o selfTestResult en falso marcan el sitio como fallido.
//  - autoconsentDone / autoconsentError: se anotan para kurth_autoconsent.
//
//  "Que no deje nada a medias": autoconsent ya deshace su CSS de ocultado previo (prehide) cuando
//  falla o tarda más de 2 s. Lo que no puede deshacer es un paso de clic que sí ocurrió (abrir el
//  panel de ajustes y no encontrar el botón de guardar). Por eso un sitio donde el opt-out falla
//  (o cuya prueba propia dice que el rechazo no quedó) queda anotado en `kurth.autoconsentFallidos` y
//  no se vuelve a intentar ahí: como mucho una vez
//  se ve a medias, después el banner queda para contestarlo a mano. La detección heurística (clics
//  por texto en botones de cualquier página) va apagada: solo actúan reglas escritas para un CMP.
//
//  Marcos: el script completo (140 KB) solo se instala en el marco principal. En los iframes corre
//  un aviso de una línea; si la URL del marco coincide con alguna regla de marcos (Sourcepoint,
//  TrustArc…), Nook le inyecta el script en ese momento. Así un iframe de anuncios no paga nada.
//

import Foundation
import WebKit
import os

@MainActor
final class KurthAutoconsent {
    static let shared = KurthAutoconsent()
    fileprivate static let log = Logger(subsystem: "com.nook.browser", category: "KurthAutoconsent")

    static let ajuste = "kurth.autoconsent"
    static let ajusteExcluidos = "kurth.autoconsentExcluidos"
    static let claveFallidos = "kurth.autoconsentFallidos"
    static var activo: Bool { UserDefaults.standard.object(forKey: ajuste) as? Bool ?? true }

    /// Apps de trabajo que nunca muestran banner de cookies: no se gasta ni la detección ahí. El
    /// dominio cubre sus subdominios (zoho.com incluye crm.zoho.com).
    static let excluidosDefault = "accounts.google.com, mail.google.com, docs.google.com, drive.google.com, calendar.google.com, meet.google.com, business.facebook.com, adsmanager.facebook.com, zoho.com"

    static let mundo = WKContentWorld.world(name: "KurthAutoconsent")
    static let nombreCanal = "kurthAutoconsent"

    /// Para la prueba sin Nook (kurth/checks/autoconsent.swift): de dónde leer Vendor.
    nonisolated(unsafe) static var carpetaDeRecursos: URL?

    // MARK: - Instalación

    private static let instalados = NSHashTable<WKUserContentController>.weakObjects()
    private static let canal = Canal()

    /// El script de contenido, envuelto: solo en http(s), una vez por marco, y con el puente de
    /// mensajes puesto antes de que autoconsent lo lea al construirse.
    static let fuente: String? = {
        guard let bundle = leer("autoconsent.playwright", "js") else { return nil }
        return WKUserScriptPrefijo + " kurth: autoconsent\n" + """
        (function () {
          if (window.__kurthAutoconsent || !/^https?:$/.test(location.protocol)) return;
          const canal = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(nombreCanal);
          if (!canal) return;
          window.__kurthAutoconsent = true;
          // Los "report" son el estado interno en cada paso: no le sirven a Nook y serían decenas
          // de mensajes por página.
          window.autoconsentSendMessage = function (m) {
            if (!m || m.type === 'report') return;
            try { canal.postMessage(m); } catch (e) {}
          };
          (function () {
        \(bundle)
          })();
        })();
        """
    }()

    /// En los iframes: solo avisa su URL. Nook decide si vale la pena el script completo.
    private static let avisoDeMarco = WKUserScriptPrefijo + " kurth: autoconsent (marcos)\n" + """
    (function () {
      if (window.top === window || !/^https?:$/.test(location.protocol)) return;
      try { window.webkit.messageHandlers.\(nombreCanal).postMessage({ type: 'kurthFrame', url: location.href }); } catch (e) {}
    })();
    """

    /// Una vez por controlador de contenido. Con el ajuste apagado no se instala nada (ni se
    /// analiza el script en cada página); al encenderlo aplica a las vistas nuevas.
    static func instalar(en webView: WKWebView) {
        guard activo, let fuente else { return }
        let controlador = webView.configuration.userContentController
        guard !instalados.contains(controlador) else { return }
        instalados.add(controlador)
        controlador.add(canal, contentWorld: mundo, name: nombreCanal)
        // Al inicio del documento: el ocultado previo tiene que llegar antes de que el banner se pinte.
        controlador.addUserScript(WKUserScript(source: fuente, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true, in: mundo))
        controlador.addUserScript(WKUserScript(source: avisoDeMarco, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false, in: mundo))
        // Las reglas se leen y se indexan fuera del hilo principal, antes de la primera página.
        Task.detached(priority: .utility) { _ = await KurthReglasAutoconsent.compartidas.cargadas() }
    }

    private final class Canal: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive mensaje: WKScriptMessage) {
            guard let cuerpo = mensaje.body as? [String: Any], let tipo = cuerpo["type"] as? String,
                  let webView = mensaje.webView else { return }
            let marco = mensaje.frameInfo
            MainActor.assumeIsolated {
                KurthAutoconsent.shared.recibir(tipo, cuerpo, marco: marco, webView: webView)
            }
        }
    }

    // MARK: - Mensajes

    private func recibir(_ tipo: String, _ cuerpo: [String: Any], marco: WKFrameInfo, webView: WKWebView) {
        let url = (cuerpo["url"] as? String) ?? marco.request.url?.absoluteString ?? ""
        switch tipo {
        case "kurthFrame":
            guard permitido(webView) else { return }
            Task {
                guard await KurthReglasAutoconsent.compartidas.hayReglaDeMarco(para: url), let fuente = Self.fuente else { return }
                // Con completion y no con async: la versión async lanza error cuando el script
                // devuelve undefined, que es lo normal aquí.
                webView.evaluateJavaScript(fuente, in: marco, in: Self.mundo) { resultado in
                    if case let .failure(error) = resultado {
                        Self.log.debug("marco sin script: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        case "init":
            let principal = marco.isMainFrame
            guard permitido(webView) else {
                responder(webView, marco, ["type": "initResp", "config": ["enabled": false], "rules": [:] as [String: Any]])
                return
            }
            Task {
                guard let reglas = await KurthReglasAutoconsent.compartidas.json(para: url, principal: principal) else { return }
                // Las reglas van como texto JSON y se leen allá con JSON.parse: pasar 80 KB de
                // arreglos anidados como argumentos obliga a WebKit a convertir objeto por objeto.
                let texto = "{\"type\":\"initResp\",\"config\":\(Self.configuracion),\"rules\":{\"compact\":\(reglas)}}"
                self.responderTexto(webView, marco, texto)
            }
        case "eval":
            guard let id = cuerpo["id"] as? String, let codigo = cuerpo["code"] as? String else { return }
            Task {
                var resultado = false
                do {
                    // El código es una expresión "(() => …)()" de eval-snippets.ts; algunas devuelven promesa.
                    let r = try await webView.callAsyncJavaScript(
                        "try { return !!(await (\(codigo))); } catch (e) { return false; }",
                        arguments: [:], in: marco, contentWorld: .page)
                    resultado = (r as? Bool) ?? ((r as? NSNumber)?.boolValue ?? false)
                } catch {
                    resultado = false
                }
                self.responder(webView, marco, ["type": "evalResp", "id": id, "result": resultado])
            }
        case "popupFound":
            let cmp = (cuerpo["cmp"] as? String) ?? "?"
            anotar(url, cmp, "banner")
            // Se vuelve a preguntar aquí: el ajuste pudo apagarse con la página abierta.
            guard permitido(webView) else { return }
            responder(webView, marco, ["type": "optOut"])
        case "optOutResult":
            let cmp = (cuerpo["cmp"] as? String) ?? "?"
            let ok = cuerpo["result"] as? Bool ?? false
            anotar(url, cmp, ok ? "rechazado" : "falló")
            if !ok, let host = Self.host(URL(string: url)) { marcarFallido(host) }
            // Un opt-out "exitoso" solo dice que los clics ocurrieron (OneTrust devuelve true aunque
            // el banner siga ahí). La prueba propia del CMP confirma que el rechazo quedó guardado.
            if ok, cuerpo["scheduleSelfTest"] as? Bool == true { responder(webView, marco, ["type": "selfTest"]) }
        case "selfTestResult":
            let ok = cuerpo["result"] as? Bool ?? false
            anotar(url, (cuerpo["cmp"] as? String) ?? "?", ok ? "comprobado" : "no se guardó")
            if !ok, let host = Self.host(URL(string: url)) { marcarFallido(host) }
        case "autoconsentDone":
            anotar(url, (cuerpo["cmp"] as? String) ?? "?", "listo")
        case "autoconsentError":
            anotar(url, "?", "error: " + String(String(describing: cuerpo["details"] ?? "").prefix(160)))
        case "cmpDetected":
            anotar(url, (cuerpo["cmp"] as? String) ?? "?", "detectado")
        default:
            break
        }
    }

    /// La configuración de autoconsent (Config en lib/types.ts). autoAction nulo: el opt-out lo
    /// manda Nook al ver popupFound, no el script por su cuenta.
    private static let configuracion: String = {
        let config: [String: Any] = [
            "enabled": true,
            "autoAction": NSNull(),
            "disabledCmps": [String](),
            "enablePrehide": true,
            "prehideTimeout": 2000,
            "enableCosmeticRules": true,
            "enableGeneratedRules": true,
            "enableHeuristicDetection": false,
            "heuristicMode": "off",
            "enablePopupMutationObserver": false,
            "detectRetries": 20,
            "isMainWorld": false,
            "visualTest": false,
            "logs": ["lifecycle": false, "rulesteps": false, "detectionsteps": false, "evals": false,
                     "errors": false, "messages": false, "waits": false],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: config)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }()

    private func responder(_ webView: WKWebView, _ marco: WKFrameInfo, _ mensaje: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: mensaje) else { return }
        responderTexto(webView, marco, String(decoding: data, as: UTF8.self))
    }

    private func responderTexto(_ webView: WKWebView, _ marco: WKFrameInfo, _ texto: String) {
        Task {
            // Sin return: optOut resuelve hasta terminar los clics y no hay nada que esperar aquí.
            // Si el marco ya navegó a otra página, WebKit falla la llamada y no pasa nada.
            _ = try? await webView.callAsyncJavaScript(
                "if (window.autoconsentReceiveMessage) { window.autoconsentReceiveMessage(JSON.parse(m)); }",
                arguments: ["m": texto], in: marco, contentWorld: Self.mundo)
        }
    }

    // MARK: - Dónde sí

    /// Por la página de arriba, no por el marco: un iframe de un CMP dentro de Gmail tampoco corre.
    private func permitido(_ webView: WKWebView) -> Bool {
        guard Self.activo, let host = Self.host(webView.url) else { return false }
        if Self.coincide(host, Self.excluidos) { return false }
        return !Self.fallidos.contains(host)
    }

    static var excluidos: [String] {
        let texto = UserDefaults.standard.string(forKey: ajusteExcluidos) ?? excluidosDefault
        return texto.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.lowercased() }.filter { !$0.isEmpty }
    }

    static func coincide(_ host: String, _ dominios: [String]) -> Bool {
        dominios.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func host(_ url: URL?) -> String? {
        guard let url, let esquema = url.scheme?.lowercased(), esquema == "http" || esquema == "https",
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static var fallidos: [String] { UserDefaults.standard.stringArray(forKey: claveFallidos) ?? [] }

    private func marcarFallido(_ host: String) {
        var lista = Self.fallidos
        guard !lista.contains(host) else { return }
        lista.append(host)
        UserDefaults.standard.set(lista, forKey: Self.claveFallidos)
        Self.log.notice("opt-out falló en \(host, privacy: .public): no se vuelve a intentar ahí")
    }

    func olvidarFallidos(_ host: String?) {
        guard let host else { UserDefaults.standard.removeObject(forKey: Self.claveFallidos); return }
        UserDefaults.standard.set(Self.fallidos.filter { $0 != host.lowercased() }, forKey: Self.claveFallidos)
    }

    // MARK: - Bitácora (para kurth_autoconsent)

    struct Evento { let fecha: Date; let host: String; let cmp: String; let que: String }
    private(set) var eventos: [Evento] = []

    private func anotar(_ url: String, _ cmp: String, _ que: String) {
        eventos.append(Evento(fecha: Date(), host: Self.host(URL(string: url)) ?? url, cmp: cmp, que: que))
        if eventos.count > 40 { eventos.removeFirst(eventos.count - 40) }
        Self.log.debug("\(que, privacy: .public) \(cmp, privacy: .public) en \(url, privacy: .private)")
    }

    // MARK: - Recursos

    fileprivate nonisolated static func leer(_ nombre: String, _ tipo: String) -> String? {
        let ruta = carpetaDeRecursos.map { $0.appendingPathComponent("\(nombre).\(tipo)").path }
            ?? Bundle.main.path(forResource: nombre, ofType: tipo)
        guard let ruta, let texto = try? String(contentsOfFile: ruta, encoding: .utf8), !texto.isEmpty else { return nil }
        return texto
    }
}

/// El marcador de los scripts propios de Nook (WKUserScript.nookOwnedPrefix, en NookBlocker): los
/// tweaks vacían los user scripts en cada navegación y solo reponen los que empiezan así.
private let WKUserScriptPrefijo = "// Nook"

// MARK: - Reglas compactas

/// compact-rules.json, indexado una vez y filtrado por URL como `filterCompactRules` de
/// autoconsent (lib/encoding.ts). Actor: el filtro corre fuera del hilo principal.
actor KurthReglasAutoconsent {
    static let compartidas = KurthReglasAutoconsent()

    private var v: Any = 1
    private var s: [Any] = []
    private var r: [[Any]] = []
    private var genericas = 0..<0
    private var especificas = 0..<0
    private var deMarcos = 0..<0
    private var finGenericas = 0
    private var finMarcos = 0
    /// Patrón compilado por índice de regla (nil adentro: ICU no lo entendió).
    private var patrones: [Int: NSRegularExpression?] = [:]
    private var listo = false
    /// La respuesta de casi todas las páginas (ninguna regla específica aplica): se arma una vez.
    private var soloGenericas: String?

    func cargadas() -> Bool {
        if listo { return !r.isEmpty }
        listo = true
        guard let texto = KurthAutoconsent.leer("autoconsent-compact-rules", "json"),
              let raiz = try? JSONSerialization.jsonObject(with: Data(texto.utf8)) as? [String: Any],
              let s = raiz["s"] as? [Any], let r = raiz["r"] as? [[Any]],
              let indice = raiz["index"] as? [String: Any],
              let g = indice["genericRuleRange"] as? [Int], let e = indice["specificRuleRange"] as? [Int],
              let m = indice["frameRuleRange"] as? [Int], g.count == 2, e.count == 2, m.count == 2,
              let fg = indice["genericStringEnd"] as? Int, let fm = indice["frameStringEnd"] as? Int else {
            return false
        }
        self.v = raiz["v"] ?? 1
        self.s = s
        self.r = r
        let rango = { (a: [Int]) in max(0, min(a[0], r.count))..<max(0, min(a[1], r.count)) }
        genericas = rango(g); especificas = rango(e); deMarcos = rango(m)
        finGenericas = min(fg, s.count); finMarcos = min(fm, s.count)
        return true
    }

    /// Las reglas para esta URL, ya como texto JSON {v, s, r}.
    func json(para url: String, principal: Bool) -> String? {
        guard cargadas() else { return nil }
        if principal {
            let propias = especificas.filter { aplica($0, url: url, principal: true) }.map { r[$0] }
            if propias.isEmpty {
                if let soloGenericas { return soloGenericas }
                soloGenericas = texto(["v": v, "s": Array(s[0..<finGenericas]), "r": Array(r[genericas])])
                return soloGenericas
            }
            return texto(["v": v, "s": s, "r": Array(r[genericas]) + propias])
        }
        let propias = deMarcos.filter { aplica($0, url: url, principal: false) }.map { r[$0] }
        return texto(["v": v, "s": Array(s[0..<finMarcos]), "r": propias])
    }

    /// ¿Alguna regla de marcos aplica a esta URL? Si no, el iframe se queda sin script.
    func hayReglaDeMarco(para url: String) -> Bool {
        guard cargadas() else { return false }
        return deMarcos.contains { aplica($0, url: url, principal: false) }
    }

    /// shouldRunRuleInContext: el contexto va en rule[4] (main y frame codificados en dos dígitos:
    /// 1 = solo marcos; 10, 12, 20, 22 = no en marcos) y el patrón de URL en rule[3].
    private func aplica(_ indice: Int, url: String, principal: Bool) -> Bool {
        let regla = r[indice]
        guard regla.count > 4 else { return false }
        let contexto = (regla[4] as? Int) ?? 0
        if principal && contexto == 1 { return false }
        if !principal && [20, 22, 10, 12].contains(contexto) { return false }
        guard let patron = regla[3] as? String, !patron.isEmpty else { return true }
        // Los patrones son de JavaScript; los que ICU no entiende cuentan como "no aplica".
        let expresion: NSRegularExpression?
        if let guardada = patrones[indice] { expresion = guardada } else {
            expresion = try? NSRegularExpression(pattern: patron)
            patrones[indice] = expresion
        }
        guard let expresion else { return false }
        return expresion.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    private func texto(_ valor: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: valor) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

#if !KURTH_CHECK
// MARK: - MCP

extension KurthAutoconsent {
    static let herramienta = AIToolDefinition(
        name: "kurth_autoconsent",
        description: "Banners de cookies contestados por Nook (autoconsent de DuckDuckGo, siempre rechazar). Dice si está activo, los sitios excluidos, los sitios donde el rechazo falló (ahí ya no se intenta) y los últimos eventos: banner, rechazado, listo, falló. olvidar: un host para volver a intentarlo ahí, o \"*\" para todos.",
        parameters: ["type": "object", "properties": ["olvidar": ["type": "string"]]]
    )

    static func llamar(_ nombre: String, _ args: [String: Any]) -> [String: Any]? {
        guard nombre == "kurth_autoconsent" else { return nil }
        if let host = args["olvidar"] as? String { shared.olvidarFallidos(host == "*" ? nil : host) }
        let formato = ISO8601DateFormatter()
        let estado: [String: Any] = [
            "activo": activo,
            "script": fuente != nil,
            "excluidos": excluidos,
            "fallidos": fallidos,
            "eventos": shared.eventos.suffix(20).map {
                ["fecha": formato.string(from: $0.fecha), "host": $0.host, "cmp": $0.cmp, "que": $0.que]
            },
        ]
        return KurthMCPTools.text(KurthMCPTools.json(estado))
    }
}
#endif
