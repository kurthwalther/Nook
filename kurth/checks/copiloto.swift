// Licensed under GPL-3.0. See LICENSE.
//
// Prueba de KurthCopilot.js sin abrir Nook: un WKWebView sin ventana carga copiloto.html, se
// instala el script en el mismo mundo aislado que usa la app y se llaman snapshot, find,
// formPlan/formFill, prepare y seVe como lo hace KurthCopilot.swift. Correr con
// kurth/checks/copiloto.sh. Cada comprobación imprime ✅ o ❌; termina con 1 si alguna falló.
//
// No prueba lo que necesita Nook: eventos nativos (click/teclas por NSEvent), diálogos, ni el
// despacho de las herramientas en Swift (batch, la guardia de confirmado).

import AppKit
import WebKit

let repo = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let fuente = try! String(contentsOf: repo.appendingPathComponent("Nook/Kurth/KurthCopilot.js"), encoding: .utf8)
let pagina = repo.appendingPathComponent("kurth/checks/copiloto.html")

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
let mundo = WKContentWorld.world(name: "KurthCopilot")
var fallas = 0

func ok(_ nombre: String, _ condicion: Bool, _ detalle: @autoclosure () -> String = "") {
    if condicion { print("✅ \(nombre)") } else { fallas += 1; print("❌ \(nombre)\n   \(detalle())") }
}

@MainActor func js(_ codigo: String, _ args: [String: Any] = [:], mundo m: WKContentWorld = mundo) async throws -> Any? {
    do { return try await webView.callAsyncJavaScript(codigo, arguments: args, in: nil, contentWorld: m) }
    catch {
        let ns = error as NSError
        throw NSError(domain: "js", code: 1, userInfo: [NSLocalizedDescriptionKey: ns.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription])
    }
}

@MainActor func pagina(_ codigo: String) async throws -> Any? { try await js(codigo, mundo: .page) }

@MainActor func correr() async {
    do {
        _ = try await js(fuente + "\nreturn true")
        ok("script instalado", try await js("return typeof window.__kurth") as? String == "object")

        // ── snapshot: shadow DOM, slot, iframe ─────────────────────────────────────────
        let foto = try await js("return window.__kurth.snapshot(400, false)") as? String ?? ""
        ok("snapshot lista el botón", foto.contains("- button \"Guardar\" [@"), foto)
        ok("snapshot da referencia a encabezados", foto.contains("- heading \"Formulario de prueba\" [@"), foto)
        ok("snapshot entra al shadow DOM abierto", foto.contains("- button \"Sombra\" [@"), foto)
        ok("snapshot ve lo asignado al slot", foto.contains("- link \"Ranura\" [@"), foto)
        ok("snapshot no lista lo de luz sin slot", !foto.contains("Sin ranura"), foto)
        ok("snapshot entra al iframe del mismo origen", foto.contains("- iframe \"Marco interno\" [@") && foto.contains("  - button \"Botón del marco\" [@"), foto)
        ok("snapshot lista el campo de archivo", foto.contains("tipo=file"), foto)
        ok("snapshot no avisa de iframes ajenos", !foto.contains("otro origen"), foto)

        // ── delta ───────────────────────────────────────────────────────────────────────
        let igual = try await js("return window.__kurth.snapshot(400, true)") as? String ?? ""
        ok("delta sin cambios lo dice", igual.contains("Sin cambios desde la foto anterior"), igual)
        _ = try await pagina("""
            document.getElementById('dinamico').innerHTML = '<button id="nuevo">Nuevo botón</button>';
            document.getElementById('ayuda').remove();
            document.getElementById('guardar').textContent = 'Guardar cambios';
            return true
            """)
        let delta = try await js("return window.__kurth.snapshot(400, true)") as? String ?? ""
        ok("delta reporta nuevos", delta.contains("Nuevos:\n") && delta.contains("Nuevo botón"), delta)
        ok("delta reporta cambiados", delta.contains("Cambiados:\n") && delta.contains("Guardar cambios"), delta)
        ok("delta reporta quitados", delta.contains("Quitados") && delta.contains("\"Ayuda\""), delta)
        ok("delta no repite lo igual", !delta.contains("\"Sombra\""), delta)

        // ── referencias estables ────────────────────────────────────────────────────────
        let refGuardar = foto.split(separator: "\n").first { $0.contains("\"Guardar\"") }.flatMap { l -> String? in
            guard let a = l.range(of: "[@"), let b = l.range(of: "]", range: a.upperBound..<l.endIndex) else { return nil }
            return String(l[a.upperBound..<b.lowerBound])
        } ?? ""
        let refDespues = try await js("return window.__kurth.describir(ref)", ["ref": refGuardar]) as? String ?? ""
        ok("la referencia sobrevive al cambio de texto", refDespues.contains("Guardar cambios"), "\(refGuardar) → \(refDespues)")
        do {
            _ = try await js("return window.__kurth.describir('e999')")
            ok("referencia inexistente falla con mensaje", false)
        } catch { ok("referencia inexistente falla con mensaje", error.localizedDescription.contains("ya no existe"), error.localizedDescription) }

        // ── find ────────────────────────────────────────────────────────────────────────
        let porRol = try await js("return window.__kurth.find({rol: 'botón'})") as? [String: Any] ?? [:]
        let lineasRol = porRol["lineas"] as? [String] ?? []
        ok("find por rol en español", lineasRol.count >= 4 && lineasRol.allSatisfy { $0.hasPrefix("- button") }, "\(lineasRol)")
        let porTexto = try await js("return window.__kurth.find({texto: 'pagar'})") as? [String: Any] ?? [:]
        ok("find por texto sin acentos ni mayúsculas", (porTexto["lineas"] as? [String])?.first?.contains("Pagar ahora") == true, "\(porTexto)")
        let porRegex = try await js("return window.__kurth.find({regex: 'marc[oa]', rol: 'textbox'})") as? [String: Any] ?? [:]
        ok("find por regex y rol combinados", (porRegex["lineas"] as? [String])?.count == 1, "\(porRegex)")
        let tope = try await js("return window.__kurth.find({regex: '.', max: 3})") as? [String: Any] ?? [:]
        ok("find respeta max y cuenta el total", (tope["lineas"] as? [String])?.count == 3 && ((tope["total"] as? NSNumber)?.intValue ?? 0) > 3, "\(tope)")
        do {
            _ = try await js("return window.__kurth.find({regex: '('})")
            ok("find con regex inválida falla con mensaje", false)
        } catch { ok("find con regex inválida falla con mensaje", error.localizedDescription.contains("Expresión regular"), error.localizedDescription) }

        // ── fill_form ───────────────────────────────────────────────────────────────────
        let campos: [[String: Any]] = [
            ["selector": "#nombre", "valor": "Kurth Walther"],
            ["selector": "#correo", "valor": "hola@kurthwalther.com"],
            ["selector": "#clave", "valor": "secreto"],
            ["selector": "#fecha", "valor": "2026-09-26"],
            ["selector": "#hora", "valor": "14:30"],
            ["selector": "#cantidad", "valor": 3],
            ["selector": "#acepto", "valor": true],
            ["selector": "#promo", "valor": "no"],
            ["selector": "input[name=envio]", "valor": "express"],
            ["selector": "#pais", "valor": "España"],
            ["selector": "#colores", "valor": ["Rojo", "a"]],
            ["selector": "#notas", "valor": "nota nueva"],
            ["selector": "#editor", "valor": "texto nuevo"],
            ["selector": "#controlado", "valor": "react"],
            ["selector": "#campoMarco", "valor": "en el marco"],
            ["selector": "#sombra", "valor": "x"],
        ]
        let plan = try await js("return window.__kurth.formPlan(campos)", ["campos": campos]) as? [[String: Any]] ?? []
        ok("formPlan resuelve todos los campos", plan.count == campos.count, "\(plan.count)")
        ok("formPlan marca las casillas como clic", plan[6]["clic"] as? Bool == true && plan[0]["clic"] as? Bool == false, "\(plan)")
        let r = try await js("return window.__kurth.formFill(campos)", ["campos": campos]) as? [String: Any] ?? [:]
        let hechos = r["hechos"] as? [String] ?? []
        let error = r["error"] as? String ?? ""
        ok("formFill se detiene en el botón (campo 16) y reporta 15 hechos", hechos.count == 15 && error.hasPrefix("Campo 16"), "\(hechos.count) — \(error)")
        let valores = try await pagina("""
            const v = (id) => document.getElementById(id).value;
            return { nombre: v('nombre'), correo: v('correo'), clave: v('clave'), fecha: v('fecha'), hora: v('hora'),
                     cantidad: v('cantidad'), acepto: document.getElementById('acepto').checked, promo: document.getElementById('promo').checked,
                     envio: document.querySelector('input[name=envio]:checked').value, pais: v('pais'),
                     colores: Array.from(document.getElementById('colores').selectedOptions).map(o => o.value).join(','),
                     notas: v('notas'), editor: document.getElementById('editor').innerText, controlado: v('controlado'),
                     eventos: window.eventos, aceptoCambios: window.aceptoCambios || 0,
                     marco: document.getElementById('marco').contentDocument.getElementById('campoMarco').value }
            """) as? [String: Any] ?? [:]
        ok("texto reemplazado", valores["nombre"] as? String == "Kurth Walther", "\(valores)")
        ok("email", valores["correo"] as? String == "hola@kurthwalther.com")
        ok("contraseña sin mostrarla en el informe", valores["clave"] as? String == "secreto" && hechos[2].contains("(contraseña escrita)"), hechos[2])
        ok("fecha", valores["fecha"] as? String == "2026-09-26")
        ok("hora", valores["hora"] as? String == "14:30")
        ok("número", valores["cantidad"] as? String == "3")
        ok("casilla marcada con change", valores["acepto"] as? Bool == true && (valores["aceptoCambios"] as? NSNumber)?.intValue == 1, "\(valores["aceptoCambios"] ?? "")")
        ok("casilla desmarcada con 'no'", valores["promo"] as? Bool == false)
        ok("radio por texto del grupo", valores["envio"] as? String == "express")
        ok("select por texto", valores["pais"] as? String == "es")
        ok("select múltiple por texto y valor", valores["colores"] as? String == "r,a", "\(valores["colores"] ?? "")")
        ok("textarea", valores["notas"] as? String == "nota nueva")
        ok("contenteditable", (valores["editor"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "texto nuevo", "\(valores["editor"] ?? "")")
        let eventos = valores["eventos"] as? [String: Any] ?? [:]
        ok("campo controlado recibe input y change", valores["controlado"] as? String == "react" && ((eventos["input"] as? NSNumber)?.intValue ?? 0) >= 1 && ((eventos["change"] as? NSNumber)?.intValue ?? 0) >= 1, "\(eventos)")
        ok("campo dentro del iframe", valores["marco"] as? String == "en el marco", "\(valores["marco"] ?? "")")

        do {
            _ = try await js("return window.__kurth.formFill(campos)", ["campos": [["selector": "#fecha", "valor": "26/09/2026"]]])
            let r2 = try await js("return window.__kurth.formFill(campos)", ["campos": [["selector": "#fecha", "valor": "26/09/2026"]]]) as? [String: Any] ?? [:]
            ok("fecha con formato malo avisa el formato", (r2["error"] as? String)?.contains("AAAA-MM-DD") == true, "\(r2)")
        }
        let sinCampo = try await js("return window.__kurth.formFill(campos)", ["campos": [["selector": "#no-existe", "valor": "x"]]]) as? [String: Any] ?? [:]
        ok("selector sin elemento avisa", (sinCampo["error"] as? String)?.contains("No hay ningún elemento") == true, "\(sinCampo)")
        do {
            _ = try await js("return window.__kurth.formPlan(campos)", ["campos": [["valor": "x"]]])
            ok("campo sin ref ni selector falla en el plan", false)
        } catch { ok("campo sin ref ni selector falla en el plan", error.localizedDescription.contains("Campo 1"), error.localizedDescription) }

        // ── prepare dentro del iframe: coordenadas de la ventana de arriba ─────────────
        let refMarco = (try await js("return window.__kurth.find({texto: 'Botón del marco'})") as? [String: Any])
            .flatMap { ($0["lineas"] as? [String])?.first }
            .flatMap { l -> String? in
                guard let a = l.range(of: "[@"), let b = l.range(of: "]", range: a.upperBound..<l.endIndex) else { return nil }
                return String(l[a.upperBound..<b.lowerBound])
            } ?? ""
        let info = try await js("return window.__kurth.prepare(ref)", ["ref": refMarco]) as? [String: Any] ?? [:]
        let topeMarco = try await pagina("return document.getElementById('marco').getBoundingClientRect().top") as? NSNumber ?? 0
        let izqMarco = try await pagina("return document.getElementById('marco').getBoundingClientRect().left") as? NSNumber ?? 0
        let y = (info["y"] as? NSNumber)?.doubleValue ?? -1
        let x = (info["x"] as? NSNumber)?.doubleValue ?? -1
        ok("prepare suma la posición del iframe", y > topeMarco.doubleValue + 3 && x > izqMarco.doubleValue + 3, "x=\(x) y=\(y) marco=(\(izqMarco), \(topeMarco))")
        ok("prepare no ve tapado el botón del marco", info["covered"] == nil || info["covered"] is NSNull, "\(info)")
        // El click por JavaScript en el marco llega y la sonda (en la ventana del marco) lo anota.
        _ = try await js("return window.__kurth.clickJS(ref)", ["ref": refMarco])
        let sonda = try await js("return window.__kurth.lastClick()") as? [String: Any] ?? [:]
        let clics = try await pagina("return document.getElementById('marco').contentWindow.clicMarco || 0") as? NSNumber ?? 0
        ok("clickJS dentro del iframe llega y la sonda lo anota", clics.intValue == 1 && sonda["onTarget"] as? Bool == true, "clics=\(clics) sonda=\(sonda)")

        // ── anillo de espera (modo con cabeza, KurthCabeza.swift) ───────────────────────
        let pagar = try await js("return window.__kurth.find({texto: 'Pagar ahora', rol: 'button', max: 1})") as? [String: Any] ?? [:]
        let lineaPagar = (pagar["lineas"] as? [String])?.first ?? ""
        let refPagar = lineaPagar.range(of: #"@e\d+"#, options: .regularExpression).map { String(lineaPagar[$0].dropFirst()) } ?? ""
        let descrito = try await js("return window.__kurth.describir(ref)", ["ref": refPagar]) as? String ?? ""
        ok("describir nombra el botón delicado", descrito == "button \"Pagar ahora\"", descrito)
        _ = try await js("return window.__kurth.marcas.elemento({id: 'espera-prueba', autor: 'agente', ref, espera: true})", ["ref": refPagar])
        let lista = try await js("return window.__kurth.marcas.lista()") as? [[String: Any]] ?? []
        ok("el anillo de espera queda registrado", lista.contains { $0["id"] as? String == "espera-prueba" && $0["tipo"] as? String == "espera" }, "\(lista)")
        ok("el anillo de espera se quita", try await js("return window.__kurth.marcas.quitar('espera-prueba')") as? Bool == true)

        // ── seVe con texto del iframe ───────────────────────────────────────────────────
        ok("seVe encuentra texto dentro del iframe", try await js("return window.__kurth.seVe('texto dentro del marco', null)") as? Bool == true)
        ok("seVe no inventa", try await js("return window.__kurth.seVe('esto no está', null)") as? Bool == false)
    } catch {
        fallas += 1
        print("❌ excepción: \(error.localizedDescription)")
    }
    print(fallas == 0 ? "\nTodo bien." : "\n\(fallas) falla(s).")
    exit(fallas == 0 ? 0 : 1)
}

final class Navegacion: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // El iframe srcdoc y el shadow DOM ya están; un cuadro más por si acaso.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Task { @MainActor in await correr() } }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("❌ no cargó la página: \(error.localizedDescription)"); exit(1)
    }
}

let navegacion = Navegacion()
webView.navigationDelegate = navegacion
webView.loadFileURL(pagina, allowingReadAccessTo: pagina.deletingLastPathComponent())
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("❌ se acabó el tiempo"); exit(1) }
app.run()
