// Licensed under GPL-3.0. See LICENSE.
//
//  KurthBeepProbe.swift
//  Nook (rama kurth)
//
//  DIAGNÓSTICO TEMPORAL (24 sep): en el chat del agente suena el aviso de error de macOS y la
//  primera teoría (el campo se desactivaba a media pulsación de Enter) no era. En la Air no se
//  puede engancharle el depurador a Nook (SIP activo y el build sin get-task-allow), así que se
//  intercepta -[NSResponder noResponderFor:], el camino habitual del aviso cuando una tecla o una
//  acción no tiene quién la reciba, y se deja en el log qué la disparó:
//    /usr/bin/log show --last 5m --predicate 'subsystem == "com.gstudios.nook.kurth" AND category == "beep"'
//  Primer resultado (24 sep, 10:53): ningún keyDown sin destinatario, solo keyUp y mouse, que no
//  suenan. Si el aviso volvió a sonar, viene de un NSBeep directo: siguiente paso, depurador con
//  get-task-allow en nuestro build o interceptar NSBeep. Quitar en cuanto se encuentre la causa.
//

import AppKit
import ObjectiveC
import os

enum KurthBeepProbe {
    private static let log = Logger(subsystem: "com.gstudios.nook.kurth", category: "beep")

    static func install() {
        let selector = NSSelectorFromString("noResponderFor:")
        guard let method = class_getInstanceMethod(NSResponder.self, selector) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let reemplazo: @convention(block) (AnyObject, Selector) -> Void = { objeto, evento in
            // Solo keyDown: suena. Los del mouse (mouseMoved, cada movimiento) también pasan por
            // aquí sin sonar, y armar la pila en cada uno gastaba CPU sin razón.
            guard evento == #selector(NSResponder.keyDown(with:)) else {
                original(objeto, selector, evento)
                return
            }
            let pila = Thread.callStackSymbols.prefix(30).joined(separator: "\n")
            log.notice("noResponderFor: \(NSStringFromSelector(evento), privacy: .public) · \(String(describing: type(of: objeto)), privacy: .public) · primer respondedor: \(String(describing: NSApp.keyWindow?.firstResponder.map { type(of: $0) }), privacy: .public)\n\(pila, privacy: .public)")
            original(objeto, selector, evento)
        }
        method_setImplementation(method, imp_implementationWithBlock(reemplazo))
    }
}
