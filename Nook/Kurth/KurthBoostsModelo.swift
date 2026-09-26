// Licensed under GPL-3.0. See LICENSE.
//
//  KurthBoostsModelo.swift
//  Nook (rama kurth)
//
//  Boosts por sitio (plan del 26 sep, punto 5): CSS y JS propios que Nook aplica solo en las páginas
//  https de un host exacto, como los Boosts de Arc. Aquí va lo que no depende de Nook (el modelo y
//  cómo se vuelve user script) para que kurth/checks/boosts.sh lo pruebe con un WKWebView suelto.
//  La tienda, la instalación en las pestañas y el MCP viven en KurthBoosts.swift.
//
//  Por qué user scripts y no _WKUserStyleSheet: la hoja de estilos de WebKit es SPI (firma que cambia
//  entre versiones) y su lugar en la cascada frente a las hojas de la página no está documentado. Una
//  <style> al final del documento es API pública, gana los empates contra la página y se ve en el
//  inspector.
//

import Foundation
import JavaScriptCore
import WebKit

struct KurthBoost: Codable, Identifiable, Equatable {
    /// Host exacto, en minúsculas: www.facebook.com no cubre facebook.com (misma regla que
    /// KurthAgentService.ReglaDeSitio).
    var host: String
    /// Nombre corto para reconocerlo ("Sin Reels"); lo pone el agente, puede ir vacío.
    var nombre: String
    var css: String
    var js: String
    var encendido: Bool
    var actualizado: Date

    var id: String { host }
    var tieneCSS: Bool { !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var tieneJS: Bool { !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var vacio: Bool { !tieneCSS && !tieneJS }
}

enum KurthBoostsModelo {
    /// Empieza con "// Nook" (WKUserScript.nookOwnedPrefix) a propósito: los tweaks y el bloqueador
    /// vacían los user scripts en cada navegación y solo reponen los que llevan ese marcador.
    /// KurthBoosts.swift lo comprueba contra la constante de NookBlocker al arrancar.
    static let prefijo = "// Nook kurth: boost"

    /// Mundo aislado propio: el JS del boost ve el DOM de la página pero no sus variables, la página
    /// no ve el suyo, y no choca con window.__kurth del copiloto (otro mundo).
    static let mundo = WKContentWorld.world(name: "KurthBoosts")

    // MARK: - Host

    /// Acepta "facebook.com", "https://www.facebook.com/reel/1" o " WWW.Facebook.com ": devuelve el
    /// host en minúsculas. Nil si no hay host o trae algo fuera de [a-z0-9.-]; el host se escribe
    /// dentro del script, así que no se aceptan caracteres que puedan romper una línea o un literal.
    static func host(de texto: String) -> String? {
        var t = texto.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let h = URL(string: t)?.host(), !h.isEmpty,
              h.unicodeScalars.allSatisfy({ permitidos.contains($0) }) else { return nil }
        return h
    }

    /// El host de una página que puede llevar boost: solo https (en http una red ajena podría
    /// hacerse pasar por el sitio y recibir el JS).
    static func host(de url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https", let h = url.host() else { return nil }
        return host(de: h)
    }

    private static let permitidos = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

    // MARK: - Validación del JS

    /// Nil si el JS es un cuerpo de función válido; si no, el error de JavaScriptCore con su línea.
    /// Se compila con el constructor de AsyncFunction (sin ejecutarlo): así un JS con llaves de más
    /// ("}); algo(); (function(){") no puede salirse del envoltorio y correr fuera de su host.
    static func errorDeSintaxis(_ js: String) -> String? {
        guard !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let contexto = JSContext() else { return nil }
        contexto.setObject(js, forKeyedSubscript: "fuente" as NSString)
        contexto.evaluateScript("(async function () {}).constructor(fuente)")
        guard let error = contexto.exception else { return nil }
        // El constructor antepone dos líneas ("async function anonymous(\n) {\n").
        if let linea = error.objectForKeyedSubscript("line")?.toInt32(), linea > 2 {
            return "\(error.toString() ?? "SyntaxError") (línea \(linea - 2))"
        }
        return error.toString() ?? "SyntaxError"
    }

    // MARK: - Scripts

    /// Pone, cambia o quita (css vacío) la <style> del boost. La deja como último hijo de <html>:
    /// después de <head> y <body>, así gana los empates contra las hojas de la página. Un observador
    /// de los hijos directos de <html> (no del árbol entero: casi nunca cambian) la regresa al final
    /// si algo se agrega después; un tope de movidas evita pelear sin fin con otro script igual.
    /// Lo usan el script de carga y la aplicación en vivo (mismo mundo, mismo estado).
    static let poner = """
    (css) => {
      const b = (window.__kurthBoost ??= { movidas: 0 });
      if (!css) {
        b.obs?.disconnect();
        b.estilo?.remove();
        window.__kurthBoost = { movidas: 0 };
        return false;
      }
      if (!b.estilo) {
        b.estilo = document.createElement("style");
        b.estilo.setAttribute("data-kurth-boost", "");
      }
      if (b.estilo.textContent !== css) b.estilo.textContent = css;
      const alFinal = () => {
        const raiz = document.documentElement;
        if (!raiz) return;
        if (raiz.lastElementChild !== b.estilo) {
          if (++b.movidas > 500) { b.obs.disconnect(); return; }
          raiz.appendChild(b.estilo);
        }
        if (b.raiz !== raiz) {
          b.raiz = raiz;
          b.obs.disconnect();
          b.obs.observe(raiz, { childList: true });
        }
      };
      if (!b.obs) {
        b.obs = new MutationObserver(alFinal);
        // Al inicio de la carga <html> puede no existir aún: se espera en el documento.
        if (!document.documentElement) b.obs.observe(document, { childList: true });
      }
      alFinal();
      return true;
    }
    """

    /// Los scripts de los boosts encendidos: uno de CSS con el mapa host → css (al inicio de la carga,
    /// antes de que la página se pinte) y uno por boost con JS (al terminar el HTML). Todos se instalan
    /// en cada página y se filtran solos por host: cambiar un boost no depende de la navegación.
    /// El JS va en su propio script para que un error suyo no se lleve el CSS ni los demás boosts.
    static func scripts(_ boosts: [KurthBoost]) -> [WKUserScript] {
        let encendidos = boosts.filter(\.encendido).sorted { $0.host < $1.host }
        var lista: [WKUserScript] = []
        let mapa = Dictionary(uniqueKeysWithValues: encendidos.filter(\.tieneCSS).map { ($0.host, $0.css) })
        if !mapa.isEmpty {
            lista.append(WKUserScript(source: fuenteCSS(mapa), injectionTime: .atDocumentStart,
                                      forMainFrameOnly: true, in: mundo))
        }
        for boost in encendidos where boost.tieneJS {
            lista.append(WKUserScript(source: fuenteJS(boost), injectionTime: .atDocumentEnd,
                                      forMainFrameOnly: true, in: mundo))
        }
        return lista
    }

    static func fuenteCSS(_ mapa: [String: String]) -> String {
        // Object.hasOwn: un host "constructor" (válido en una intranet) no debe leer Object.prototype.
        """
        \(prefijo) css
        (() => {
          if (location.protocol !== "https:") return;
          const mapa = \(literal(mapa));
          const h = location.hostname;
          if (Object.hasOwn(mapa, h)) (\(poner))(mapa[h]);
        })();
        """
    }

    static func fuenteJS(_ boost: KurthBoost) -> String {
        let h = literal(boost.host)
        // Cuerpo de una función async (ya validado con errorDeSintaxis): puede usar await, y un error
        // queda en la consola con el host en vez de romper la página.
        return """
        \(prefijo) js \(boost.host)
        if (location.protocol === "https:" && location.hostname === \(h)) {
        (async function () {
        \(boost.js)
        }).call(window).catch((e) => console.error("[Boost " + \(h) + "]", e));
        }
        """
    }

    /// Literal de JavaScript: JSON es un subconjunto de JS desde ES2019 (incluye U+2028/2029).
    private static func literal<T: Encodable>(_ valor: T) -> String {
        let codificador = JSONEncoder()
        codificador.outputFormatting = [.sortedKeys]
        guard let datos = try? codificador.encode(valor) else { return "null" }
        return String(decoding: datos, as: UTF8.self)
    }
}
