// Licensed under GPL-3.0. See LICENSE.
//
//  KurthSuspensionGancho.swift
//  NookWeb (rama kurth)
//
//  Ganchos de la suspensión de pestañas (Nook/Kurth/KurthSuspension.swift, en la app): este
//  paquete no ve el código de la app, así que ella los llena al arrancar. Sin llenar, PageSession
//  se comporta como upstream: al descargar suelta la vista y al volver pide la URL desde cero.
//
//  Lo que se conserva por aquí es el `interactionState` de WKWebView: el historial atrás/adelante,
//  el scroll y lo escrito en formularios de la página. Título, favicon y URL ya viven en
//  PageSession y no necesitan gancho.
//

import Foundation

@MainActor
public enum KurthSuspensionGancho {
    /// Justo antes de soltar las vistas de una página (PageSession.unload): guardar su estado.
    public static var guardar: ((PageSession) -> Void)?
    /// Al crear la vista de una página que vuelve: el estado guardado si sigue valiendo para su
    /// URL actual, o nil para cargar normal. Se consume al devolverlo.
    public static var estadoGuardado: ((PageSession) -> Any?)?
    /// La página terminó (tearDown): lo guardado ya no sirve.
    public static var olvidar: ((UUID) -> Void)?
}
