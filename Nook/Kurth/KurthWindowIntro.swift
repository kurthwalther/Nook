// Licensed under GPL-3.0. See LICENSE.
//
//  KurthWindowIntro.swift
//  Nook (rama kurth)
//
//  Apertura de ventana como Zen (ZenStartup.mjs, el "watermark"): el fondo se ve desde el
//  primer cuadro y todo lo demás —barra lateral, página, barra superior— aparece JUNTO en
//  un fundido cuando la página ya tiene qué mostrar. Antes Nook aparecía por partes: fondo,
//  barra, tarjeta blanca y al final la página.
//  Solo opacidad: mover frames dispararía el relayout de todos los WKWebView (KurthBarProbe).
//

import SwiftUI
import NookWeb

struct KurthWindowIntro: ViewModifier {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.nookSettings) private var nookSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Por ventana: una vez que apareció, no vuelve a esconderse.
    @State private var revealed = false

    /// Tope para no bloquear nunca: si la página tarda, la ventana aparece igual.
    private static let maxWait: TimeInterval = 0.3

    func body(content: Content) -> some View {
        content
            .opacity(revealed || !nookSettings.didFinishOnboarding ? 1 : 0)
            .onAppear {
                // Detrás del onboarding la ventana ya existe a opacidad 0: ahí no hay intro.
                guard nookSettings.didFinishOnboarding else { revealed = true; return }
                if pageReady { reveal() }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxWait) { reveal() }
            }
            .onChange(of: pageReady) { _, ready in
                if ready { reveal() }
            }
    }

    /// Lista para mostrarse: sin página (vista vacía) o con la navegación ya confirmada.
    private var pageReady: Bool {
        guard let session = browserManager.tabs.selectedSession(in: windowState) else { return true }
        switch session.loadingState {
        case .didCommit, .didFinish: return true
        default: return false
        }
    }

    private func reveal() {
        guard !revealed else { return }
        withAnimation(reduceMotion ? KurthMotion.reduced : .easeOut(duration: 0.18)) {
            revealed = true
        }
    }
}

extension View {
    func kurthWindowIntro() -> some View { modifier(KurthWindowIntro()) }
}
