// Licensed under GPL-3.0. See LICENSE.
//
//  KurthTraduccionControl.swift
//  Nook (rama kurth)
//
//  Lo visible de la traducción: un solo ícono `translate` dentro de la cápsula de dirección, junto
//  a recargar, como Safari. Sin barras de aviso ni banners (criterio de Kurth: discreto). Aparece
//  solo si la página está en un idioma que no es del sistema y Translation lo soporta.
//
//  Estados del ícono: gris = se ofrece; el cometa de KurthReloadButton = traduciendo; color de
//  acento = traducida (un clic regresa al original).
//
//  KurthTraduccionAncla es la vista invisible que cada barra lleva debajo: vigila la carga de la
//  pestaña a la vista para detectar el idioma, y es la que pide la descarga del par de idiomas
//  con `.translationTask` (ver KurthTraduccion.swift: esa hoja solo la da una vista).
//

import SwiftUI
import Translation
import WebKit
import NookDesign
import NookWeb

struct KurthTraduccionBoton: View {
    let webView: WKWebView
    let ventanaID: UUID

    var body: some View {
        let t = KurthTraduccion.of(webView)
        Button {
            switch t.estado {
            case .traduciendo, .traducida: Task { await t.verOriginal() }
            default: Task { await t.traducir(ventanaID: ventanaID) }
            }
        } label: {
            Label {
                Text(t.estado == .traducida ? "Ver original" : "Traducir")
            } icon: {
                if t.estado == .traduciendo {
                    KurthLoadingIndicator().transition(.opacity)
                } else {
                    Image(systemName: "translate")
                        .foregroundStyle(t.estado == .traducida ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .transition(.opacity)
                }
            }
        }
        .animation(NookDesign.Motion.quick, value: t.estado)
        .help(ayuda(t))
    }

    private func ayuda(_ t: KurthTraduccion) -> String {
        let idioma = t.idioma.map(KurthTraductor.nombre) ?? ""
        switch t.estado {
        case .traduciendo: return "Traduciendo… (clic para cancelar)"
        case .traducida: return "Ver original"
        case .error(let m): return "No se pudo traducir: \(m)"
        default: return idioma.isEmpty ? "Traducir página" : "Traducir del \(idioma)"
        }
    }
}

/// Invisible, una por ventana (KurthTopBarView la lleva de fondo).
struct KurthTraduccionAncla: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @AppStorage(KurthTraduccion.ajuste) private var ofrecer = true

    private struct Vigilancia: Equatable {
        let web: ObjectIdentifier?
        let url: URL?
        let cargando: Bool
        let ofrecer: Bool
    }

    var body: some View {
        let session = browserManager.tabs.controllableSession(in: windowState)
        let webView = session.flatMap { browserManager.webViewCoordinator?.getWebView(for: $0.itemID, in: windowState.id) }
        let peticion = KurthTraduccionDescarga.shared.peticion
        let mia = peticion?.ventanaID == windowState.id ? peticion : nil
        let ventanaID = windowState.id

        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // Detectar al terminar de cargar; al empezar otra carga, el estado de la pestaña se
            // reinicia (su JavaScript se fue con el documento anterior).
            .task(id: Vigilancia(web: webView.map(ObjectIdentifier.init), url: session?.url,
                                 cargando: session?.isLoading ?? false, ofrecer: ofrecer)) {
                guard let webView, let session else { return }
                let t = KurthTraduccion.of(webView)
                if session.isLoading { t.nuevaCarga(); return }
                // Con el ajuste apagado no se detecta nada, salvo que esta pestaña venga traduciendo.
                guard ofrecer || t.pegajosa != nil else { return }
                await t.detectar(ventanaID: ventanaID)
            }
            // La hoja de descarga del sistema. La sesión de aquí solo prepara (descarga) y se
            // suelta; si la ventana se cierra a la mitad, la tarea se cancela y la espera falla.
            .translationTask(mia?.config) { sesion in
                let descarga = KurthTraduccionDescarga.shared
                guard let id = descarga.peticion?.id else { return }
                descarga.tomar(id)
                do {
                    try await sesion.prepareTranslation()
                    descarga.terminar(id, nil)
                } catch {
                    descarga.terminar(id, error)
                }
            }
    }
}
