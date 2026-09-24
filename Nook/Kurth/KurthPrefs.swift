// Licensed under GPL-3.0. See LICENSE.
//
//  KurthPrefs.swift
//  Nook (rama kurth)
//
//  Ajustes de la capa Kurth que tienen que cambiar EN VIVO en vistas que no son nuestras
//  (WebsiteView recorta la página con KurthChrome.pageShape). @AppStorage solo refresca la vista
//  que lo declara; este objeto es @Observable, así que cualquier vista que lo lea al dibujarse
//  (aunque sea a través de KurthChrome) se redibuja cuando cambia.
//

import Foundation
import Observation

@MainActor
@Observable
final class KurthPrefs {
    static let shared = KurthPrefs()

    /// Radio de la página: 8 es el concéntrico (ventana 16 − separación 8); 10 para comparar.
    var pageRadius: Double {
        didSet { UserDefaults.standard.set(pageRadius, forKey: "kurth.pageRadius") }
    }

    /// Ancho del panel del agente: el último que dejó Kurth al soltar el borde, 330 la primera vez.
    /// Es un valor de usuario, no un ajuste: se lee al crear cada ventana (BrowserManager.setupWindowState)
    /// y se escribe en AISidebarResizeView. Upstream lo traía fijo en 350 y lo olvidaba al reiniciar.
    var aiSidebarWidth: Double {
        didSet { UserDefaults.standard.set(aiSidebarWidth, forKey: "kurth.aiSidebarWidth") }
    }

    private init() {
        let saved = UserDefaults.standard.double(forKey: "kurth.pageRadius")
        pageRadius = saved > 0 ? saved : 8
        let ancho = UserDefaults.standard.double(forKey: "kurth.aiSidebarWidth")
        aiSidebarWidth = ancho > 0 ? ancho : 330
    }
}
