// Licensed under GPL-3.0. See LICENSE.
//
//  KurthWorkflowsReplayModelo.swift
//  Nook (rama kurth)
//
//  El replay exacto de un workflow grabado, sin LLM. Kurth, 26 sep: "los programados replican lo
//  que el usuario hizo, pero debe ser exacto o casi exacto por si cambia ligeramente el diseño".
//  Antes cada corrida era una orden al agente, que leía el skill y decidía cada clic; ahora Nook
//  repite los pasos del JSON en orden y el agente solo entra si un paso no aparece en la página.
//
//  Este archivo es la parte que no sabe de WebKit ni de Nook: el registro de cada paso, cómo se
//  sustituyen los parámetros, cómo se lee una tecla grabada y el bucle que recorre los pasos. La
//  página la pone quien lo usa, a través de KurthReplayPagina: en Nook, las pestañas reales con
//  KurthCopilot (KurthWorkflowsReplay.swift); en kurth/checks/replay.sh, un WKWebView sin ventana.
//  Así la prueba ejercita este mismo bucle, no una copia.
//
//  Qué hace con cada paso:
//   · navegar: si la página ya está ahí (host y ruta; la consulta cambia sola) no hace nada; si la
//     navegación la provocó el paso anterior, la espera; si no, va directo a la dirección grabada.
//   · pestaña nueva / cambiar / cerrar: una pestaña de la corrida por cada pestaña de la grabación.
//   · clic, escribir, elegir, marcar, enviar, tecla en un campo: localizar (KurthReplay.js, seis
//     niveles) y actuar con el copiloto. Hasta 15 s por paso: el localizador se repite mientras
//     tanto, así que "esperar a que aparezca el elemento del siguiente paso" es buscarlo.
//   · Si no aparece: primero, si la página no es la grabada, se va a la grabada y se busca otra
//     vez; después, el respaldo (el agente del panel) para ese paso; si tampoco, "falló en el paso N".
//   · «secreto»: no se reproduce; la corrida se detiene con "necesita que inicies sesión".
//   · Lo que no se repite: narración, cambio de Space, ⌘-clic (la pestaña nueva se abre en su paso),
//     archivos (la grabación solo tiene el nombre).
//

import Foundation

// MARK: - Registro de la corrida

/// Con qué se encontró (o se resolvió) cada paso. Es lo que Kurth ve en el detalle.
enum KurthReplayNivel: String, Codable, Equatable {
    case exacto, normalizado, etiqueta, selector, difuso
    case posicion = "posición"
    /// Lo resolvió el agente del panel (respaldo).
    case agente
    /// No había nada que buscar: una dirección, una tecla en la página, un desplazamiento.
    case directo
    /// La navegación ya había pasado por el paso anterior (un clic en un enlace).
    case yaEstaba = "ya-estaba"
    case omitido
    /// No se encontró con ningún nivel.
    case ninguno

    /// Encontrado, pero no igual que en la grabación: Kurth debería verlo.
    var cambio: Bool { self == .difuso || self == .posicion || self == .agente }
}

struct KurthWorkflowPasoCorrida: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Número del paso entre las acciones (el mismo que en el texto para el agente).
    var indice: Int
    /// El KurthWorkflowPaso, para "Actualizar el workflow con esto".
    var paso: UUID
    var descripcion: String
    var nivel: KurthReplayNivel
    var ok: Bool
    var ms: Int
    var detalle: String?
    /// El nombre grabado y el de hoy, cuando no fueron iguales.
    var grabado: String?
    var encontrado: String?
    var selectorNuevo: String?
    var similitud: Double?

    init(indice: Int, paso: UUID, descripcion: String, nivel: KurthReplayNivel, ok: Bool, ms: Int, detalle: String? = nil) {
        self.indice = indice
        self.paso = paso
        self.descripcion = descripcion
        self.nivel = nivel
        self.ok = ok
        self.ms = ms
        self.detalle = detalle
    }

    /// "El botón cambió de «Descargar informe» a «Descargar reporte»".
    var frase: String? {
        guard let grabado, let encontrado, !encontrado.isEmpty, grabado != encontrado else { return nil }
        return "Cambió de «\(grabado)» a «\(encontrado)»"
    }
}

// MARK: - Lo que el bucle le pide a la página

enum KurthReplayAccion: Equatable {
    case clic(ref: String, doble: Bool)
    case escribir(ref: String, texto: String)
    case elegir(ref: String, opcion: String)
    case marcar(ref: String, valor: Bool)
    case tecla(ref: String?, tecla: String, mods: [String])
    case enviar(ref: String)
    case desplazar(pantallas: Double)
}

/// Un error de la página que ya viene en lenguaje de persona (lo que dice el registro).
struct KurthReplayError: LocalizedError {
    enum Tipo { case general, rechazado, detenido }
    let tipo: Tipo
    let errorDescription: String?
    init(_ mensaje: String, _ tipo: Tipo = .general) {
        self.tipo = tipo
        errorDescription = mensaje
    }
}

@MainActor
protocol KurthReplayPagina: AnyObject {
    /// La dirección de la pestaña actual de la corrida; nil si todavía no hay.
    var urlActual: String? { get }
    /// Abre una pestaña para `clave` (la pestaña de la grabación) con esa dirección, espera su carga
    /// y la deja como actual. Si el paso anterior ya abrió una (enlace con target=_blank), la adopta
    /// y devuelve true.
    func abrir(_ url: String, clave: String?) async throws -> Bool
    /// Pasa a la pestaña de `clave` si la corrida ya la tiene.
    func usar(_ clave: String?) -> Bool
    func cerrar(_ clave: String?)
    func navegar(_ url: String) async throws
    /// Espera a que la página deje de cargar y de cambiar, hasta `maximo` segundos.
    func esperarQuieta(maximo: Double) async
    /// window.__kurthReplay.localizar(d): {ref, nivel, nombre, similitud, selector, …} o {ref: null}.
    func localizar(_ d: [String: Any]) async throws -> [String: Any]
    func actuar(_ a: KurthReplayAccion) async throws -> String
    /// Justo antes de una acción: para saber después si abrió una pestaña.
    func antesDeActuar()
}

/// Lo que devuelve el respaldo (el agente del panel) para un paso que no apareció.
enum KurthReplayRespaldo {
    case resuelto(String)
    case fallo(String)
}

// MARK: - Utilidades puras

enum KurthReplayModelo {

    /// Los parámetros de la corrida en lugar de los valores de la grabación. El ejemplo de cada
    /// parámetro ES el valor grabado (lo escribe el agente al registrar el skill), así que se busca
    /// ese texto. En una sola pasada con marcas, para que el valor de uno no se vuelva a sustituir
    /// por el ejemplo de otro. En direcciones solo ejemplos de 3 caracteres o más (un "1" cambiaría
    /// medio URL) y también en su forma codificada (?q=bolsa%20negra).
    static func sustituir(_ texto: String, parametros: [KurthWorkflowParametro], valores: [String: String],
                          enDireccion: Bool = false) -> String {
        let cambios = parametros
            .filter { !$0.ejemplo.isEmpty && (!enDireccion || $0.ejemplo.count >= 3) }
            .compactMap { p -> (String, String)? in
                guard let v = valores[p.nombre], v != p.ejemplo else { return nil }
                return (p.ejemplo, v)
            }
            .sorted { $0.0.count > $1.0.count }
        guard !cambios.isEmpty else { return texto }
        var s = texto
        var reemplazos: [String: String] = [:]
        for (i, (ejemplo, valor)) in cambios.enumerated() {
            let marca = "\u{1}\(i)\u{1}"
            var formas = [(ejemplo, valor)]
            if enDireccion {
                let permitido = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
                if let e = ejemplo.addingPercentEncoding(withAllowedCharacters: permitido),
                   let v = valor.addingPercentEncoding(withAllowedCharacters: permitido), e != ejemplo {
                    formas.append((e, v))
                    formas.append((e.replacingOccurrences(of: "%20", with: "+"), v.replacingOccurrences(of: "%20", with: "+")))
                }
            }
            for (j, (desde, hacia)) in formas.enumerated() where s.contains(desde) {
                let m = marca + "\(j)"
                s = s.replacingOccurrences(of: desde, with: m)
                reemplazos[m] = hacia
            }
        }
        for (m, v) in reemplazos { s = s.replacingOccurrences(of: m, with: v) }
        return s
    }

    /// Misma página: mismo sitio (sin www) y misma ruta. La consulta y el fragmento cambian solos
    /// (sesiones, filtros, marcas de tiempo) y no dicen que sea otra página.
    static func mismaPagina(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, let ua = URL(string: a), let ub = URL(string: b) else { return false }
        func host(_ u: URL) -> String {
            let h = (u.host() ?? "").lowercased()
            return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        }
        func ruta(_ u: URL) -> String {
            let r = u.path()
            return r.count > 1 && r.hasSuffix("/") ? String(r.dropLast()) : r
        }
        return ua.scheme == ub.scheme && host(ua) == host(ub) && ruta(ua) == ruta(ub)
    }

    /// "⌘K" → ("k", ["cmd"]); "Esc" → ("Escape", []); "⇧Tab" → ("Tab", ["shift"]). Así la grabó
    /// KurthGrabadora.js y así la entiende press_key.
    static func tecla(_ grabada: String) -> (tecla: String, mods: [String]) {
        let mapa: [Character: String] = ["⌃": "ctrl", "⌥": "alt", "⇧": "shift", "⌘": "cmd"]
        var mods: [String] = []
        var resto = Substring(grabada)
        while let c = resto.first, let m = mapa[c] { mods.append(m); resto = resto.dropFirst() }
        let nombres = ["Esc": "Escape", "Espacio": "Space", "↓": "ArrowDown", "↑": "ArrowUp", "←": "ArrowLeft",
                       "→": "ArrowRight", "⌫": "Backspace", "⌦": "Delete"]
        var t = String(resto)
        t = nombres[t] ?? t
        if t.count == 1 { t = t.lowercased() }
        return (t, mods)
    }

    /// Lo que se le pasa al localizador: la descripción grabada del elemento.
    static func descripcion(_ p: KurthWorkflowPaso) -> [String: Any] {
        var d: [String: Any] = ["tipo": p.tipo.rawValue, "rol": p.rol ?? "", "nombre": p.nombre ?? ""]
        if let s = p.selector { d["selector"] = s }
        if let h = p.href { d["href"] = h }
        if let pos = p.pos, pos.count == 2 { d["pos"] = pos }
        if let o = p.orden { d["orden"] = o }
        return d
    }

    /// "12 pasos · 1 difuso", "Falló en el paso 5: …".
    static func resumen(_ pasos: [KurthWorkflowPasoCorrida], total: Int) -> String {
        let hechos = pasos.filter(\.ok).count
        let cambios = pasos.filter { $0.ok && $0.nivel.cambio }.count
        var s = "\(hechos) de \(total) pasos"
        if cambios > 0 { s += " · \(cambios) \(cambios == 1 ? "cambió" : "cambiaron") en la página" }
        return s
    }
}

// MARK: - El bucle

@MainActor
final class KurthReplayEjecutor {
    let pagina: KurthReplayPagina
    /// Tope para encontrar el elemento de un paso (el localizador se repite mientras tanto).
    var limitePorPaso: Double = 15
    /// Cuánto se espera a que la página se aquiete después de cada acción.
    var quietudMaxima: Double = 5
    /// Un difuso no se acepta antes de esto: la página puede estar todavía pintando el exacto.
    var esperaAntesDeDifuso: Double = 1.5
    /// El agente del panel para el paso que no apareció. nil: sin respaldo, el paso falla.
    var respaldo: ((KurthWorkflowPaso, Int, String) async -> KurthReplayRespaldo)?
    var alPaso: ((KurthWorkflowPasoCorrida) -> Void)?
    var alEmpezarPaso: ((Int, Int) -> Void)?

    init(pagina: KurthReplayPagina) { self.pagina = pagina }

    struct Resultado {
        var estado: KurthWorkflowCorrida.Estado
        var resumen: String
        var pasos: [KurthWorkflowPasoCorrida]
        /// El número del paso que falló, si falló.
        var fallo: Int?
        var necesitaSesion = false
    }

    private var registro: [KurthWorkflowPasoCorrida] = []
    private var ultimaAccion: (t: Double, tipo: KurthWorkflowPaso.Tipo)?

    func correr(_ wf: KurthWorkflow, valores: [String: String]) async -> Resultado {
        registro = []
        ultimaAccion = nil
        let acciones = wf.pasos.filter { !$0.esNarracion }
        let total = acciones.count
        for (i, p) in acciones.enumerated() {
            let n = i + 1
            if Task.isCancelled { return terminar(.fallo, "Detenida en el paso \(n) de \(total)", fallo: n, total: total) }
            alEmpezarPaso?(n, total)
            let inicio = Date()
            do {
                let r = try await paso(p, n: n, wf: wf, valores: valores, siguientes: Array(acciones.dropFirst(n)))
                anotar(r, inicio)
                if !r.ok {
                    return terminar(.fallo, "Falló en el paso \(n): \(r.detalle ?? r.descripcion)", fallo: n, total: total)
                }
            } catch is CancellationError {
                return terminar(.fallo, "Detenida en el paso \(n) de \(total)", fallo: n, total: total)
            } catch let e as Parada {
                var r = KurthWorkflowPasoCorrida(indice: n, paso: p.id, descripcion: KurthWorkflowsModelo.lineaCorta(p),
                                                 nivel: .omitido, ok: false, ms: 0, detalle: e.mensaje)
                r.grabado = p.nombre
                anotar(r, inicio)
                var res = terminar(.fallo, e.mensaje, fallo: n, total: total)
                res.necesitaSesion = e.sesion
                return res
            } catch {
                let detalle = (error as? KurthReplayError)?.errorDescription ?? error.localizedDescription
                var r = KurthWorkflowPasoCorrida(indice: n, paso: p.id, descripcion: KurthWorkflowsModelo.lineaCorta(p),
                                                 nivel: .ninguno, ok: false, ms: 0, detalle: detalle)
                r.grabado = p.nombre
                anotar(r, inicio)
                let tipo = (error as? KurthReplayError)?.tipo
                let texto = tipo == .detenido ? "Detenida en el paso \(n): \(detalle)"
                    : tipo == .rechazado ? "Paso \(n): \(detalle)" : "Falló en el paso \(n): \(detalle)"
                return terminar(.fallo, texto, fallo: n, total: total)
            }
            // Lo que el paso haya provocado (una navegación, una lista que se abre) termina antes del siguiente.
            if [.clic, .escribir, .elegir, .marcar, .tecla, .enviar, .navegar, .pestañaNueva].contains(p.tipo) {
                await pagina.esperarQuieta(maximo: quietudMaxima)
            }
        }
        return terminar(.termino, KurthReplayModelo.resumen(registro, total: total), fallo: nil, total: total)
    }

    /// Una salida que no es error de la página: secreto, archivo. Se detiene sin respaldo.
    private struct Parada: Error {
        let mensaje: String
        var sesion = false
    }

    private func anotar(_ r: KurthWorkflowPasoCorrida, _ inicio: Date) {
        var r = r
        r.ms = Int(Date().timeIntervalSince(inicio) * 1000)
        registro.append(r)
        alPaso?(r)
    }

    private func terminar(_ estado: KurthWorkflowCorrida.Estado, _ resumen: String, fallo: Int?, total: Int) -> Resultado {
        Resultado(estado: estado, resumen: resumen, pasos: registro, fallo: fallo)
    }

    private func hecho(_ p: KurthWorkflowPaso, _ n: Int, _ nivel: KurthReplayNivel, _ detalle: String? = nil) -> KurthWorkflowPasoCorrida {
        KurthWorkflowPasoCorrida(indice: n, paso: p.id, descripcion: KurthWorkflowsModelo.lineaCorta(p), nivel: nivel, ok: true, ms: 0, detalle: detalle)
    }

    // MARK: Un paso

    private func paso(_ p: KurthWorkflowPaso, n: Int, wf: KurthWorkflow, valores: [String: String],
                      siguientes: [KurthWorkflowPaso]) async throws -> KurthWorkflowPasoCorrida {
        let dir = { (u: String?) in u.map { KurthReplayModelo.sustituir($0, parametros: wf.parametros, valores: valores, enDireccion: true) } }
        switch p.tipo {
        case .voz, .nota:
            return hecho(p, n, .omitido)

        case .space:
            return hecho(p, n, .omitido, "La corrida trabaja en su propia pestaña; el Space no cambia.")

        case .navegar:
            guard let url = dir(p.url) else { return hecho(p, n, .omitido, "Sin dirección grabada.") }
            if pagina.urlActual == nil || p.detalle == "inicio" && !pagina.usar(p.tab) {
                _ = try await pagina.abrir(url, clave: p.tab)
                return hecho(p, n, .directo, url)
            }
            _ = pagina.usar(p.tab)
            if KurthReplayModelo.mismaPagina(pagina.urlActual, url) { return hecho(p, n, .yaEstaba) }
            // La provocó el paso anterior (un clic en un enlace, un Enter): se le da tiempo a llegar.
            if let a = ultimaAccion, [.clic, .tecla, .enviar, .escribir].contains(a.tipo), p.t - a.t < 5 {
                let limite = Date().addingTimeInterval(6)
                while Date() < limite {
                    if KurthReplayModelo.mismaPagina(pagina.urlActual, url) { return hecho(p, n, .yaEstaba) }
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            try await pagina.navegar(url)
            return hecho(p, n, .directo, url)

        case .pestañaNueva:
            // Sin dirección propia, la de la primera navegación que tuvo esa pestaña.
            let url = dir(p.url ?? siguientes.first { $0.tab == p.tab && $0.tipo == .navegar }?.url)
            guard let url else { return hecho(p, n, .omitido, "La pestaña no tenía dirección.") }
            let adoptada = try await pagina.abrir(url, clave: p.tab)
            return hecho(p, n, adoptada ? .yaEstaba : .directo, url)

        case .cambiarPestaña:
            if pagina.usar(p.tab) { return hecho(p, n, .directo) }
            guard let url = dir(p.url) else { return hecho(p, n, .omitido, "Una pestaña de antes de grabar, sin dirección.") }
            _ = try await pagina.abrir(url, clave: p.tab)
            return hecho(p, n, .directo, url)

        case .cerrarPestaña:
            pagina.cerrar(p.tab)
            return hecho(p, n, .directo)

        case .scroll:
            try await asegurarPestaña(p, dir)
            let pantallas = Double(p.detalle?.split(separator: " ").first.flatMap { Double($0) } ?? 1)
            _ = try await pagina.actuar(.desplazar(pantallas: p.valor == "arriba" ? -pantallas : pantallas))
            return hecho(p, n, .directo)

        case .archivo:
            throw Parada(mensaje: "No puedo subir «\(p.valor ?? "el archivo")»: la grabación solo guarda su nombre.")

        case .tecla where (p.nombre ?? "").isEmpty && (p.selector ?? "").isEmpty:
            try await asegurarPestaña(p, dir)
            let (t, mods) = KurthReplayModelo.tecla(p.tecla ?? "Enter")
            pagina.antesDeActuar()
            _ = try await pagina.actuar(.tecla(ref: nil, tecla: t, mods: mods))
            ultimaAccion = (p.t, p.tipo)
            return hecho(p, n, .directo)

        case .clic where (p.tecla ?? "").contains("⌘") || (p.tecla ?? "").contains("⌃"):
            // ⌘-clic abre en otra pestaña; su paso "pestaña nueva" trae la dirección.
            return hecho(p, n, .omitido, "⌘-clic: la pestaña nueva se abre en su propio paso.")

        case .clic, .escribir, .elegir, .marcar, .enviar, .tecla:
            if p.tipo == .escribir, p.secreto == true || (p.valor ?? "").contains("«secreto»") {
                throw Parada(mensaje: "Necesita que inicies sesión: el paso \(n) escribe una contraseña o un código, y eso no se graba.", sesion: true)
            }
            try await asegurarPestaña(p, dir)
            var registroPaso: KurthWorkflowPasoCorrida
            let ref: String
            if let h = try await buscar(p, dir) {
                ref = h.ref
                registroPaso = hecho(p, n, h.nivel)
                registroPaso.similitud = h.similitud
                if h.nivel != .exacto, let nombre = h.nombre, nombre != p.nombre {
                    registroPaso.grabado = p.nombre
                    registroPaso.encontrado = nombre
                }
                if h.nivel != .exacto, let s = h.selector, s != p.selector { registroPaso.selectorNuevo = s }
            } else {
                let motivo = "No encontré \(KurthWorkflowsModelo.rolHumano(p.rol)) «\(p.nombre ?? p.selector ?? "?")» en \(pagina.urlActual ?? "la página")."
                guard let respaldo else {
                    var r = hecho(p, n, .ninguno, motivo)
                    r.ok = false
                    r.grabado = p.nombre
                    return r
                }
                switch await respaldo(p, n, motivo) {
                case .resuelto(let que):
                    ultimaAccion = (p.t, p.tipo)
                    var r = hecho(p, n, .agente, que)
                    r.grabado = p.nombre
                    return r
                case .fallo(let porque):
                    var r = hecho(p, n, .ninguno, motivo + " El agente tampoco: " + porque)
                    r.ok = false
                    r.grabado = p.nombre
                    return r
                }
            }
            pagina.antesDeActuar()
            let valor = KurthReplayModelo.sustituir(p.valor ?? "", parametros: wf.parametros, valores: valores)
            switch p.tipo {
            case .clic: _ = try await pagina.actuar(.clic(ref: ref, doble: p.doble == true))
            case .escribir: _ = try await pagina.actuar(.escribir(ref: ref, texto: valor))
            case .elegir: _ = try await pagina.actuar(.elegir(ref: ref, opcion: valor))
            case .marcar: _ = try await pagina.actuar(.marcar(ref: ref, valor: p.valor != "no"))
            case .enviar: _ = try await pagina.actuar(.enviar(ref: ref))
            default:
                let (t, mods) = KurthReplayModelo.tecla(p.tecla ?? "Enter")
                _ = try await pagina.actuar(.tecla(ref: ref, tecla: t, mods: mods))
            }
            ultimaAccion = (p.t, p.tipo)
            return registroPaso
        }
    }

    /// Un paso de página ocurre en la pestaña donde se grabó. Si la corrida todavía no tiene ninguna
    /// (la grabación empezó en una página que no era web), se abre con la dirección del paso.
    private func asegurarPestaña(_ p: KurthWorkflowPaso, _ dir: (String?) -> String?) async throws {
        if pagina.usar(p.tab) || pagina.urlActual != nil { return }
        guard let url = dir(p.url) else { throw KurthReplayError("El paso no dice en qué página ocurrió.") }
        _ = try await pagina.abrir(url, clave: p.tab)
    }

    struct Hallazgo {
        let ref: String
        let nivel: KurthReplayNivel
        let nombre: String?
        let similitud: Double?
        let selector: String?
    }

    /// Busca hasta el tope del paso. Si la página no es la grabada y a los 3 s no aparece, va a la
    /// grabada una vez (un clic que antes navegaba y hoy no, una dirección que cambió de ruta).
    private func buscar(_ p: KurthWorkflowPaso, _ dir: (String?) -> String?) async throws -> Hallazgo? {
        let d = KurthReplayModelo.descripcion(p)
        let inicio = Date()
        let limite = inicio.addingTimeInterval(limitePorPaso)
        var fuiALaGrabada = false
        var difuso: Hallazgo?
        while true {
            try Task.checkCancellation()
            // Si la página está navegando, WebKit corta el JavaScript con un error: eso es "todavía
            // no aparece", no un fallo del paso.
            let r: [String: Any]
            do { r = try await pagina.localizar(d) } catch is CancellationError { throw CancellationError() } catch { r = [:] }
            if let ref = r["ref"] as? String, !ref.isEmpty,
               let nivel = (r["nivel"] as? String).flatMap(KurthReplayNivel.init(rawValue:)) {
                let h = Hallazgo(ref: ref, nivel: nivel, nombre: r["nombre"] as? String,
                                 similitud: (r["similitud"] as? NSNumber)?.doubleValue ?? r["similitud"] as? Double,
                                 selector: r["selector"] as? String)
                guard nivel == .difuso || nivel == .posicion else { return h }
                // Un parecido se acepta cuando ya no hay más que esperar: la página pudo no haber
                // pintado todavía el exacto.
                difuso = h
                if Date().timeIntervalSince(inicio) >= esperaAntesDeDifuso { return h }
            } else {
                difuso = nil
            }
            let transcurrido = Date().timeIntervalSince(inicio)
            if !fuiALaGrabada, transcurrido > 3, let url = dir(p.url), !KurthReplayModelo.mismaPagina(pagina.urlActual, url) {
                fuiALaGrabada = true
                try await pagina.navegar(url)
                continue
            }
            if Date() > limite { return difuso }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}
