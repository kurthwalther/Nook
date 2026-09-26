// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarResizeView.swift
//  Nook
//
//  Created by Maciek Bagiński on 30/07/2025.
//

import SwiftUI
import NookDesign
import NookWeb
import NookUI

struct SidebarResizeView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.nookSettings) var nookSettings
    @State private var isResizing = false
    @State private var isHovering = false
    @State private var startingWidth: CGFloat = 0
    @State private var startingMouseX: CGFloat = 0
    @StateObject private var dragLockManager = DragLockManager.shared
    @State private var dragSessionID: String = UUID().uuidString
    @State private var hoverTask: Task<Void, Never>?

    /// kurth: en la barra lateral flotante (SidebarHoverOverlayView) también se redimensiona;
    /// allí isSidebarVisible es falso, así que las guardas de abajo lo dejan pasar con esto.
    var kurthEnFlotante = false

    private let minWidth = NookDesign.Size.sidebarMin
    private let maxWidth: CGFloat = 520
    private let defaultWidth: CGFloat = 250

    private var sitsOnRight: Bool {
        nookSettings.sidebarPosition == .right
    }

    private var hitAreaOffset: CGFloat {
        sitsOnRight ? 5 : -5
    }

    var body: some View {
        ZStack {
            // kurth: sin línea en la orilla, como Finder o Mail: solo el cursor ↔ (Kurth, 25 sep). La
            // cápsula gris que había parecía la barra de scroll.

            Rectangle()
                .fill(Color.clear)
                .frame(width: 12)
                .padding(.vertical, 30)
                .offset(x: hitAreaOffset)
                .contentShape(.interaction, .rect)
                .onTapGesture(count: 2) {
                    guard windowState.isSidebarVisible || kurthEnFlotante else { return } // kurth
                    withAnimation(NookDesign.Motion.spring) {
                        browserManager.updateSidebarWidth(defaultWidth, for: windowState)
                    }
                    browserManager.saveSidebarWidthToDefaults() // kurth
                }
                .onHoverTracking { hovering in
                    guard windowState.isSidebarVisible || kurthEnFlotante else { return } // kurth

                    hoverTask?.cancel()

                    if hovering && !isResizing {
                        hoverTask = Task {
                            try? await Task.sleep(for: .seconds(0.1))
                            guard !Task.isCancelled else { return }
                            isHovering = true
                            NSCursor.resizeLeftRight.set()
                        }
                    } else {
                        isHovering = false
                        if !isResizing {
                            NSCursor.arrow.set()
                        }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in
                            guard windowState.isSidebarVisible || kurthEnFlotante else { return } // kurth

                            if !isResizing {
                                guard dragLockManager.startDrag(ownerID: dragSessionID) else {
                                    return
                                }

                                startingWidth = windowState.sidebarWidth
                                startingMouseX = value.startLocation.x
                                isResizing = true
                                if kurthEnFlotante { HoverSidebarManager.kurthRedimensionando = true } // kurth
                                NSCursor.resizeLeftRight.set()
                            }

                            let currentMouseX = value.location.x
                            let mouseMovement = sitsOnRight ? (startingMouseX - currentMouseX) : (currentMouseX - startingMouseX)
                            let newWidth = startingWidth + mouseMovement
                            let clampedWidth = max(minWidth, min(maxWidth, newWidth))

                            browserManager.updateSidebarWidth(clampedWidth, for: windowState)
                        }
                        .onEnded { _ in
                            isResizing = false
                            HoverSidebarManager.kurthRedimensionando = false // kurth
                            dragLockManager.endDrag(ownerID: dragSessionID)
                            // kurth: upstream solo guardaba el ancho al ocultar o mostrar la barra; si
                            // la redimensionabas y cerrabas Nook, volvía al de antes.
                            browserManager.saveSidebarWidthToDefaults()

                            if isHovering {
                                NSCursor.resizeLeftRight.set()
                            } else {
                                NSCursor.arrow.set()
                            }
                        }
                )
        }
        .frame(width: 3)
    }
}
