// Licensed under GPL-3.0. See LICENSE.
//
//  KurthProgresoDeCarga.swift
//  Nook (rama kurth)
//
//  El progreso de carga dentro de la cápsula de la dirección, como Safari: una línea fina en su
//  orilla de abajo que avanza con `estimatedProgress` (lo que WebKit calcula de lo ya recibido) y se
//  desvanece al terminar.
//
//  Reemplaza a WebsiteLoadingIndicator en la barra flotante (26 sep). Aquel no medía nada: pintaba
//  un ancho fijo por etapa (50, 150, 300 pt; 50 también en reposo), centrado sobre la orilla de la
//  ventana, blanco al 30 %, que en una página clara no se veía. Lo sigue usando la barra de upstream.
//
//  Va recortada por la forma de su contenedor (la cápsula la recorta con su curva), así que en las
//  puntas se afina siguiendo el borde, igual que en Safari.
//

import SwiftUI
import WebKit
import NookDesign

struct KurthProgresoDeCarga: View {
    let webView: WKWebView?
    @State private var estado = Estado()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geo.size.width * estado.progreso, height: KurthEscala.pt(2))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .opacity(estado.visible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { estado.animar = !reduceMotion; estado.seguir(webView) }
        .onChange(of: webView.map(ObjectIdentifier.init)) { _, _ in estado.seguir(webView) }
    }

    @MainActor
    @Observable
    final class Estado {
        private(set) var progreso: CGFloat = 0
        private(set) var visible = false
        @ObservationIgnored var animar = true
        @ObservationIgnored private weak var webView: WKWebView?
        @ObservationIgnored private var observaciones: [NSKeyValueObservation] = []
        @ObservationIgnored private var salida: Task<Void, Never>?

        func seguir(_ nuevo: WKWebView?) {
            guard nuevo !== webView else { return }
            observaciones.removeAll()
            salida?.cancel()
            webView = nuevo
            // Al cambiar de pestaña la línea toma el estado de la nueva sin animar: no es un avance.
            progreso = 0
            visible = false
            guard let nuevo else { return }
            if nuevo.isLoading { empezar(nuevo.estimatedProgress, animado: false) }
            observaciones = [
                nuevo.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                    MainActor.assumeIsolated { self?.avanzar(wv) }
                },
                nuevo.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                    MainActor.assumeIsolated { self?.cambioDeCarga(wv) }
                },
            ]
        }

        private func cambioDeCarga(_ wv: WKWebView) {
            if wv.isLoading { empezar(wv.estimatedProgress, animado: true) } else { terminar() }
        }

        private func empezar(_ valor: Double, animado: Bool) {
            salida?.cancel()
            // WebKit arranca en 0.1: se ve desde el primer instante que algo pasó.
            let inicio = max(CGFloat(valor), 0.1)
            if !visible { progreso = 0 }
            visible = true
            withAnimation(animado && animar ? .easeOut(duration: 0.2) : nil) { progreso = max(progreso, inicio) }
        }

        private func avanzar(_ wv: WKWebView) {
            guard wv.isLoading, visible else { return }
            let valor = CGFloat(wv.estimatedProgress)
            // Nunca hacia atrás: una redirección vuelve a empezar la cuenta de WebKit y la línea
            // regresando se lee como error.
            guard valor > progreso else { return }
            withAnimation(animar ? .easeOut(duration: 0.25) : nil) { progreso = valor }
        }

        private func terminar() {
            guard visible else { return }
            withAnimation(animar ? .easeOut(duration: 0.15) : nil) { progreso = 1 }
            salida?.cancel()
            salida = Task { [weak self] in
                // Llega al final, se queda un instante y se va; luego vuelve a cero ya invisible.
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self else { return }
                withAnimation(.easeOut(duration: 0.3)) { self.visible = false }
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled, !self.visible else { return }
                self.progreso = 0
            }
        }
    }
}
