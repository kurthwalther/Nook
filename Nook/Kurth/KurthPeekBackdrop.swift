// Licensed under GPL-3.0. See LICENSE.
import SwiftUI

/// kurth: con Peek abierto la página de atrás se encoge a 97 %, como Glance de Zen
/// (GLANCE_BACKGROUND_SCALE). Escucha las mismas notificaciones que PeekOverlayView,
/// porque el @Published de PeekManager no siempre llega.
private struct KurthPeekBackdrop: ViewModifier {
    @State private var isPeeking = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPeeking ? 0.97 : 1, anchor: .center)
            .animation(.spring(duration: 0.4, bounce: 0.2), value: isPeeking)
            .onReceive(NotificationCenter.default.publisher(for: .peekDidActivate)) { _ in isPeeking = true }
            .onReceive(NotificationCenter.default.publisher(for: .peekDidDeactivate)) { _ in isPeeking = false }
    }
}

extension View {
    func kurthPeekBackdrop() -> some View { modifier(KurthPeekBackdrop()) }
}
