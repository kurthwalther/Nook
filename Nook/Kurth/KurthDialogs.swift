// Licensed under GPL-3.0. See LICENSE.
//
//  KurthDialogs.swift
//  Nook (rama kurth)
//
//  Diálogos de JavaScript (alert, confirm, prompt) que el agente puede contestar con
//  handle_dialog (KurthCopilot). Sin esto se trababa en el primer "¿Estás seguro?": la hoja de
//  NSAlert sale sobre la ventana y el agente no la ve.
//
//  Los ganchos están en BrowserManager+NookWeb (presentAlert/Confirm/Prompt):
//   - Con ventana: el diálogo sale como siempre y además se registra; contestarlo desde el agente
//     cierra la misma hoja con la respuesta.
//   - Sin ventana (la pestaña del agente en segundo plano): antes se cancelaba sola. Si el agente
//     tocó esa pestaña, ahora espera hasta 60 s a que la conteste; si no, como antes.
//

import AppKit
import WebKit

@MainActor
enum KurthDialogs {
    struct Pendiente {
        let tipo: String       // "alert", "confirm", "prompt"
        let mensaje: String
        let responder: (_ aceptar: Bool, _ texto: String?) -> Void
    }

    private static var pendientes: [ObjectIdentifier: Pendiente] = [:]
    /// Vistas web en las que el agente ha actuado: solo en esas se espera su respuesta.
    private static var delAgente = Set<ObjectIdentifier>()

    static func marcarDelAgente(_ webView: WKWebView) { delAgente.insert(ObjectIdentifier(webView)) }
    static func esDelAgente(_ webView: WKWebView) -> Bool { delAgente.contains(ObjectIdentifier(webView)) }

    static func registrar(_ webView: WKWebView, _ pendiente: Pendiente) {
        pendientes[ObjectIdentifier(webView)] = pendiente
    }

    static func olvidar(_ webView: WKWebView) {
        pendientes[ObjectIdentifier(webView)] = nil
    }

    static func pendiente(_ webView: WKWebView) -> Pendiente? {
        pendientes[ObjectIdentifier(webView)]
    }

    /// Contesta el diálogo pendiente de esa vista. false si no había.
    static func responder(_ webView: WKWebView, aceptar: Bool, texto: String?) -> Bool {
        guard let p = pendientes.removeValue(forKey: ObjectIdentifier(webView)) else { return false }
        p.responder(aceptar, texto)
        return true
    }

    /// Para una vista sin ventana: registra el diálogo y lo deja esperar al agente hasta 60 s.
    /// `listo` recibe la respuesta; si nadie contesta, se llama con (false, nil).
    static func esperarAlAgente(_ webView: WKWebView, tipo: String, mensaje: String,
                                listo: @escaping (_ aceptar: Bool, _ texto: String?) -> Void) {
        var contestado = false
        let una: (Bool, String?) -> Void = { aceptar, texto in
            guard !contestado else { return }
            contestado = true
            listo(aceptar, texto)
        }
        registrar(webView, Pendiente(tipo: tipo, mensaje: mensaje, responder: una))
        Task { @MainActor [weak webView] in
            try? await Task.sleep(for: .seconds(60))
            guard let webView, !contestado else { return }
            olvidar(webView)
            una(false, nil)
        }
    }
}
