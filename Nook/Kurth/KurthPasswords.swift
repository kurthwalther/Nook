// Licensed under GPL-3.0. See LICENSE.
//
//  KurthPasswords.swift
//  Nook (rama kurth)
//
//  Contraseñas de Apple (Passwords / llavero de iCloud) en cualquier página, sin permisos de Apple.
//
//  Por qué así: la extensión oficial "iCloud Passwords" habla con un ayudante del sistema
//  (PasswordManagerBrowserExtensionHelper) que lleva un launch constraint: solo arranca bajo
//  navegadores de una lista de Apple o con el entitlement web-browser.public-key-credential, y Nook
//  no tiene ninguno de los dos. En cambio, un campo de contraseña nativo de AppKit
//  (NSSecureTextField con contentType = .password) recibe el botón "Passwords…" del sistema en
//  cualquier app, sin entitlement ni associated domains: pide Touch ID y entrega usuario y contraseña.
//  Verificado el 24 sep 2026 con una ventana de prueba.
//
//  Flujo: KurthPasswords.js pone una llave dentro del campo de acceso con foco → al pulsarla llega
//  "pedir" con el rectángulo del campo → aquí se montan dos campos nativos invisibles encima
//  (usuario + contraseña) y el de contraseña toma el foco → AppKit dibuja "Passwords…" debajo y
//  se pulsa solo si se le encuentra (si no, lo pulsa el usuario) → el sistema llena los campos
//  nativos → se copian a la página por JavaScript y los campos nativos desaparecen.
//  Cubre contraseñas, no llaves de acceso (passkeys): eso sí requiere el entitlement.
//
//  La credencial elegida se recuerda dos minutos para el mismo host: Google pide el correo en una
//  página y la contraseña en la siguiente, y la segunda se llena sola al tomar el foco.
//

import AppKit
import WebKit
import NookBlocker
import os

@MainActor
final class KurthPasswords {
    static let shared = KurthPasswords()
    fileprivate static let log = Logger(subsystem: "com.nook.browser", category: "KurthPasswords")

    static let ajuste = "kurth.passwords"
    static var activo: Bool { UserDefaults.standard.object(forKey: ajuste) as? Bool ?? true }
    static let vidaDeReciente: TimeInterval = 120

    // MARK: - Instalación en cada vista web

    private static let instalados = NSHashTable<WKUserContentController>.weakObjects()
    private static let canal = Canal()
    private static let fuente: String? = {
        guard let ruta = Bundle.main.path(forResource: "KurthPasswords", ofType: "js"),
              let js = try? String(contentsOfFile: ruta, encoding: .utf8), !js.isEmpty else { return nil }
        return js
    }()

    /// Una vez por controlador de contenido (las vistas que comparten configuración lo comparten).
    static func instalar(en webView: WKWebView) {
        guard activo, let fuente else { return }
        let controlador = webView.configuration.userContentController
        guard !instalados.contains(controlador) else { return }
        instalados.add(controlador)
        controlador.add(canal, contentWorld: KurthCopilot.mundo, name: "kurthPasswords")
        // El prefijo "// Nook" es el marcador de WKUserScript+NookOwned: los tweaks (YouTube, Facebook,
        // SponsorBlock…) vacían los scripts en cada navegación y solo vuelven a poner los que lo llevan.
        controlador.addUserScript(WKUserScript(source: WKUserScript.nookOwnedPrefix + " kurth: contraseñas\n" + fuente,
                                               injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: KurthCopilot.mundo))
    }

    private final class Canal: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive mensaje: WKScriptMessage) {
            guard mensaje.frameInfo.isMainFrame, let cuerpo = mensaje.body as? [String: Any],
                  let tipo = cuerpo["tipo"] as? String, let webView = mensaje.webView else { return }
            MainActor.assumeIsolated {
                switch tipo {
                case "pedir": KurthPasswords.shared.pedir(webView, cuerpo)
                case "foco": KurthPasswords.shared.foco(webView, cuerpo)
                default: break
                }
            }
        }
    }

    // MARK: - Petición en curso

    private var sesion: Sesion?
    private var reciente: Reciente?
    /// Qué pasó en la última petición (para kurth_passwords_status): botón encontrado, intentos, fin.
    fileprivate var ultima: [String: Any] = [:]
    private struct Reciente { let host: String; let usuario: String; let contrasena: String; let fecha: Date }

    fileprivate func pedir(_ webView: WKWebView, _ cuerpo: [String: Any]) {
        guard sesion == nil, webView.window != nil,
              let r = cuerpo["rect"] as? [String: Any],
              let x = (r["x"] as? NSNumber)?.doubleValue, let y = (r["y"] as? NSNumber)?.doubleValue,
              let w = (r["w"] as? NSNumber)?.doubleValue, let h = (r["h"] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return }
        let s = Sesion(webView: webView, host: Self.host(webView),
                       rect: Self.aVista(CGRect(x: x, y: y, width: w, height: h), webView))
        sesion = s
        s.empezar { [weak self] resultado in self?.terminar(s, resultado) }
    }

    private func terminar(_ s: Sesion, _ resultado: Sesion.Resultado) {
        guard sesion === s else { return }
        sesion = nil
        guard case let .credencial(usuario, contrasena) = resultado,
              let webView = s.webView, Self.host(webView) == s.host else { return }
        reciente = Reciente(host: s.host, usuario: usuario, contrasena: contrasena, fecha: Date())
        llenar(webView, usuario: usuario, contrasena: contrasena)
    }

    /// Un campo de contraseña tomó el foco: si hace menos de dos minutos se eligió una credencial
    /// para este mismo host (paso 1 de Google), se llena sin volver a pedir.
    fileprivate func foco(_ webView: WKWebView, _ cuerpo: [String: Any]) {
        guard cuerpo["esPassword"] as? Bool == true, let r = reciente, r.host == Self.host(webView),
              Date().timeIntervalSince(r.fecha) < Self.vidaDeReciente else { return }
        reciente = nil
        llenar(webView, usuario: nil, contrasena: r.contrasena)
    }

    private func llenar(_ webView: WKWebView, usuario: String?, contrasena: String?) {
        let args: [String: Any] = ["usuario": usuario ?? "", "contrasena": contrasena ?? ""]
        Task {
            do {
                let r = try await webView.callAsyncJavaScript(
                    "return window.__kurthClaves ? window.__kurthClaves.llenar(usuario, contrasena) : null",
                    arguments: args, in: nil, contentWorld: KurthCopilot.mundo)
                Self.log.notice("llenado: \(String(describing: r), privacy: .public)")
            } catch {
                Self.log.error("no se pudo llenar: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancelar() { sesion?.cancelar() }

    // MARK: - Geometría

    /// Rectángulo en el viewport de la página (px CSS) → vista web (puntos; WKWebView es flipped).
    static func aVista(_ r: CGRect, _ webView: WKWebView) -> CGRect {
        let escala = max(webView.pageZoom * webView.magnification, 0.01)
        let m = webView.obscuredContentInsets
        return CGRect(x: r.minX * escala + m.left, y: r.minY * escala + m.top,
                      width: r.width * escala, height: r.height * escala)
    }

    static func host(_ webView: WKWebView) -> String { webView.url?.host?.lowercased() ?? "" }

    // MARK: - MCP (diagnóstico)

    static let tools: [AIToolDefinition] = [
        AIToolDefinition(
            name: "kurth_passwords_status",
            description: "Contraseñas de Apple en la capa Kurth: si el llenado está activo, si hay una petición abierta (campos nativos montados esperando al sistema) y si hay una credencial reciente por usar en el siguiente campo de contraseña del mismo host. cancelar: true cierra la petición abierta.",
            parameters: ["type": "object", "properties": ["cancelar": ["type": "boolean"]]]
        ),
    ]

    static func llamar(_ nombre: String, _ args: [String: Any]) -> [String: Any]? {
        guard nombre == "kurth_passwords_status" else { return nil }
        if args["cancelar"] as? Bool == true { shared.cancelar() }
        var estado: [String: Any] = ["activo": activo, "peticionAbierta": shared.sesion != nil, "script": fuente != nil]
        if !shared.ultima.isEmpty { estado["ultimaPeticion"] = shared.ultima }
        if let r = shared.reciente {
            estado["reciente"] = ["host": r.host, "usuario": r.usuario, "edadSegundos": Int(Date().timeIntervalSince(r.fecha))]
        }
        let texto = (try? JSONSerialization.data(withJSONObject: estado, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? String(describing: estado)
        return ["content": [["type": "text", "text": texto]], "isError": false]
    }

    // MARK: - Una petición: los campos nativos y la espera del sistema

    @MainActor
    final class Sesion {
        enum Resultado { case credencial(String, String), cancelado }

        private(set) weak var webView: WKWebView?
        let host: String
        private let contenedor = NSView()
        private let usuario = CampoUsuario()
        private let contrasena = CampoSecreto()
        private var reloj: Timer?
        private let inicio = Date()
        private var fin: ((Resultado) -> Void)?
        private var botonPulsado = false
        private var intentos = 0

        init(webView: WKWebView, host: String, rect: CGRect) {
            self.webView = webView
            self.host = host
            contenedor.frame = rect
            for campo in [usuario as NSTextField, contrasena] {
                campo.frame = contenedor.bounds
                campo.autoresizingMask = [.width, .height]
                contenedor.addSubview(campo)
            }
        }

        func empezar(_ fin: @escaping (Resultado) -> Void) {
            self.fin = fin
            KurthPasswords.shared.ultima = ["inicio": ISO8601DateFormatter().string(from: inicio), "host": host,
                                             "rect": NSStringFromRect(contenedor.frame), "boton": "buscando", "intentos": 0,
                                             "ventanaFrame": NSStringFromRect(webView?.window?.frame ?? .zero), "pantallaAlto": NSScreen.main?.frame.height ?? 0,
                                             "pantallas": NSScreen.screens.map { NSStringFromRect($0.frame) }]
            guard let webView, let ventana = webView.window else { return terminar(.cancelado) }
            webView.addSubview(contenedor)
            usuario.alCancelar = { [weak self] in self?.terminar(.cancelado) }
            contrasena.alCancelar = usuario.alCancelar
            ventana.makeFirstResponder(contrasena)
            reloj = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tic() }
            }
            // AppKit dibuja "Passwords…" un instante después de que el campo toma el foco.
            for retardo in [0.15, 0.45, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + retardo) { [weak self] in self?.pulsarBoton() }
            }
        }

        func cancelar() { terminar(.cancelado) }

        private func tic() {
            let p = contrasena.stringValue
            if !p.isEmpty { return terminar(.credencial(usuario.stringValue, p)) }
            guard let ventana = contenedor.window, webView?.window === ventana else { return terminar(.cancelado) }
            if Date().timeIntervalSince(inicio) > 120 { return terminar(.cancelado) }
            // Mientras el sistema muestra su selector nuestra ventana deja de ser la principal. Si
            // vuelve a serlo y el foco ya no está en nuestros campos, el usuario se fue a otra cosa.
            if ventana.isKeyWindow, Date().timeIntervalSince(inicio) > 1.0, !esNuestro(ventana.firstResponder) {
                terminar(.cancelado)
            }
        }

        private func esNuestro(_ r: NSResponder?) -> Bool {
            guard let r else { return false }
            if r === usuario || r === contrasena { return true }
            if let editor = r as? NSTextView, let dueño = editor.delegate as? NSTextField,
               dueño === usuario || dueño === contrasena { return true }
            return false
        }

        private func terminar(_ resultado: Resultado) {
            guard let fin else { return }
            self.fin = nil
            reloj?.invalidate()
            reloj = nil
            let ventana = contenedor.window
            if case .credencial = resultado { KurthPasswords.shared.ultima["fin"] = "credencial" } else { KurthPasswords.shared.ultima["fin"] = "cancelado" }
            KurthPasswords.shared.ultima["segundos"] = Int(Date().timeIntervalSince(inicio))
            if esNuestro(ventana?.firstResponder) { ventana?.makeFirstResponder(webView) }
            contenedor.removeFromSuperview()
            usuario.stringValue = ""
            contrasena.stringValue = ""
            fin(resultado)
        }

        // El botón "Passwords…" no vive en nuestra ventana: AppKit lo pone en una ventanita propia
        // (SPRoundedWindow) pegada al campo. Se busca esa ventana, y dentro un control que pulsar; si
        // no hay control, se le manda un clic sintético al centro (la ventana es solo el botón). Si
        // nada de eso aparece, el botón queda a la vista bajo el campo y lo pulsa el usuario.
        private func pulsarBoton() {
            guard fin != nil, !botonPulsado, let ventana = contenedor.window else { return }
            let candidatas = NSApp.windows.filter { $0 !== ventana && $0.isVisible && Self.pareceAutoFill($0) }
            KurthPasswords.shared.ultima["ventanaAutoFill"] = candidatas.map { String(describing: type(of: $0)) + " " + NSStringFromRect($0.frame) }
            KurthPasswords.shared.ultima["vistasAutoFill"] = candidatas.flatMap { [String(describing: type(of: $0.contentView))] + Self.vistas(en: $0.contentView) }.prefix(30).map { $0 }
            if let v = candidatas.first {
                botonPulsado = true
                if let control = Self.botonAutoFill(en: v.contentView) ?? Self.control(en: v.contentView) {
                    let titulo = (control as? NSButton)?.title ?? ""
                    KurthPasswords.shared.ultima["boton"] = String(describing: type(of: control)) + " «" + titulo + "»"
                    KurthPasswords.log.notice("botón AutoFill: \(String(describing: type(of: control)), privacy: .public)")
                    control.performClick(nil)
                } else {
                    KurthPasswords.shared.ultima["boton"] = "clic sintético en " + String(describing: type(of: v))
                    Self.clic(en: v)
                }
                for retardo in [0.8, 2.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + retardo) { [weak self] in
                        guard let self, let ventana = self.contenedor.window else { return }
                        KurthPasswords.shared.ultima["trasClic\(retardo)"] = [
                            "ventanaKey": ventana.isKeyWindow, "appActiva": NSApp.isActive,
                            "keyWindow": NSApp.keyWindow.map { String(describing: type(of: $0)) + " " + $0.title } ?? "ninguna",
                            "focoNuestro": self.esNuestro(ventana.firstResponder),
                            "ventanas": NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) + " " + $0.title + " " + NSStringFromRect($0.frame) },
                        ] as [String: Any]
                    }
                }
                return
            }
            intentos += 1
            KurthPasswords.shared.ultima["intentos"] = intentos
            if intentos >= 3 {
                KurthPasswords.shared.ultima["boton"] = "no encontrado"
                KurthPasswords.shared.ultima["ventanas"] = NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) + " " + $0.title + " " + NSStringFromRect($0.frame) }
            }
        }

        private static func pareceAutoFill(_ w: NSWindow) -> Bool {
            let n = String(describing: type(of: w)).lowercased()
            return n.contains("autofill") || n.contains("sprounded") || n.contains("passwordpicker") || n.contains("credentialpicker")
        }

        private static func control(en vista: NSView?) -> NSControl? {
            guard let vista else { return nil }
            for sub in vista.subviews {
                if let c = sub as? NSControl { return c }
                if let c = control(en: sub) { return c }
            }
            return nil
        }

        private static func vistas(en vista: NSView?, nivel: Int = 0) -> [String] {
            guard let vista, nivel < 6 else { return [] }
            var lista: [String] = []
            for sub in vista.subviews {
                lista.append(String(repeating: "·", count: nivel) + String(describing: type(of: sub)) + " " + NSStringFromRect(sub.frame))
                lista += vistas(en: sub, nivel: nivel + 1)
            }
            return lista
        }

        /// Clic dentro de nuestro propio proceso: no necesita permiso de Accesibilidad.
        private static func clic(en w: NSWindow) {
            guard let cv = w.contentView else { return }
            let punto = cv.convert(NSPoint(x: cv.bounds.midX, y: cv.bounds.midY), to: nil)
            let t = ProcessInfo.processInfo.systemUptime
            for tipo in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: tipo, location: punto, modifierFlags: [], timestamp: t,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: tipo == .leftMouseDown ? 1 : 0) {
                    w.sendEvent(e)
                }
            }
        }

        private static func botonAutoFill(en vista: NSView?) -> NSButton? {
            guard let vista else { return nil }
            for sub in vista.subviews {
                if let b = sub as? NSButton, esAutoFill(b) { return b }
                if let b = botonAutoFill(en: sub) { return b }
            }
            return nil
        }

        private static func esAutoFill(_ b: NSButton) -> Bool {
            let clase = String(describing: type(of: b)).lowercased()
            if clase.contains("autofill") || clase.contains("password") { return true }
            let t = b.title.lowercased()
            return t.hasPrefix("passwords") || t.hasPrefix("contraseñas")
        }

    }

    // MARK: - Campos invisibles

    /// Sin borde, sin fondo, sin anillo de foco y con el texto transparente: el sistema los ve como
    /// campos de acceso normales, la persona no los ve. Escape cancela.
    fileprivate static func volverInvisible(_ campo: NSTextField, tipo: NSTextContentType) {
        campo.contentType = tipo
        campo.isBordered = false
        campo.drawsBackground = false
        campo.focusRingType = .none
        campo.textColor = .clear
        campo.backgroundColor = .clear
        campo.placeholderString = nil
        campo.usesSingleLineMode = true
        campo.cell?.isScrollable = true
        campo.font = NSFont.systemFont(ofSize: 1)
    }

    fileprivate static func ocultarCursor(_ campo: NSTextField) {
        (campo.currentEditor() as? NSTextView)?.insertionPointColor = .clear
    }

    final class CampoUsuario: NSTextField, NSTextFieldDelegate {
        var alCancelar: (() -> Void)?
        init() { super.init(frame: .zero); KurthPasswords.volverInvisible(self, tipo: .username); delegate = self }
        required init?(coder: NSCoder) { nil }
        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder(); KurthPasswords.ocultarCursor(self); return ok
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { alCancelar?(); return true }
            return false
        }
    }

    final class CampoSecreto: NSSecureTextField, NSTextFieldDelegate {
        var alCancelar: (() -> Void)?
        init() { super.init(frame: .zero); KurthPasswords.volverInvisible(self, tipo: .password); delegate = self }
        required init?(coder: NSCoder) { nil }
        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder(); KurthPasswords.ocultarCursor(self); return ok
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { alCancelar?(); return true }
            return false
        }
    }
}
