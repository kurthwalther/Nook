// Licensed under GPL-3.0. See LICENSE.
//
//  KurthThemePickerOverlay.swift
//  Nook (rama kurth)
//
//  El selector de tema como capa flotante DENTRO de la ventana (el patrón de
//  ExtensionLibraryOverlay: un NSPanel no-key saldría con el vidrio inactivo). Se ancla al borde
//  de la ventana —junto a la barra lateral si está fija— y nunca a la barra que aparece al pasar
//  el mouse, que se cierra en cuanto el cursor sale. Tocar fuera o Esc cierra y guarda.
//

import SwiftUI
import NookDesign
import NookWeb

extension KurthThemeStore {
    /// Abre el selector para el Space de esta ventana.
    func openPicker(window: BrowserWindowState, tabs: TabsController) {
        guard !window.isIncognito, let spaceID = window.spaceID else { return }
        beginEditing(spaceID: spaceID, accentHex: tabs.space(spaceID)?.accentHex, tabs: tabs)
    }
}

struct KurthThemePickerOverlay: View {
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(TabsController.self) private var tabs
    @Environment(WindowRegistry.self) private var windowRegistry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let store = KurthThemeStore.shared
        let isOpen = store.editingSpaceID != nil
            && store.editingSpaceID == windowState.spaceID
            && windowRegistry.activeWindowId == windowState.id

        ZStack(alignment: .topLeading) {
            if isOpen, let draft = store.draft {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { store.endEditing(tabs: tabs) }

                // El get lee el borrador vivo, no el `draft` capturado: con el capturado, cada escritura
                // de un mismo gesto partía del valor viejo y la última deshacía a las anteriores.
                KurthThemePicker(theme: Binding(get: { store.draft ?? draft }, set: { store.updateDraft($0) }))
                    .nookGlassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.leading, leadingInset)
                    // Más abajo que la franja de los semáforos y la barra de arriba.
                    .padding(.top, 72)
                    .transition(.scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity))
                    .onExitCommand { store.endEditing(tabs: tabs) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(KurthMotion.respecting(reduceMotion, isOpen ? KurthMotion.reveal : KurthMotion.dismiss), value: isOpen)
        // Si la ventana cambia de Space con el selector abierto, se guarda y se cierra.
        .onChange(of: windowState.spaceID) { _, _ in
            if store.editingSpaceID != nil, store.editingSpaceID != windowState.spaceID { store.endEditing(tabs: tabs) }
        }
    }

    /// A la derecha de la barra lateral: la fija, o la que aparece al pasar el mouse (que se
    /// queda abierta mientras se edita), para no taparla.
    private var leadingInset: CGFloat {
        windowState.isSidebarVisible
            ? windowState.sidebarWidth + 12
            : max(windowState.sidebarWidth, windowState.savedSidebarWidth) + KurthChrome.overlayInset + 12
    }
}
