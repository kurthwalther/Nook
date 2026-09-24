// Licensed under GPL-3.0. See LICENSE.
//
//  KurthSenalarOverlay.swift
//  Nook (rama kurth)
//
//  El modo caja de "Señalar": encima de la página, cursor en cruz; arrastrar dibuja el rectángulo
//  y al soltar KurthSenalar lo convierte en referencia (recorte + texto + elementos). Es una capa
//  nativa y no de la página, así que funciona también sobre imágenes, video y canvas. Esc sale.
//

import SwiftUI
import NookDesign
import NookWeb

struct KurthSenalarOverlay: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    @State private var inicio: CGPoint?
    @State private var actual: CGPoint?

    private var activo: Bool { KurthSenalar.shared.modoCaja == windowState.id }

    var body: some View {
        if activo {
            GeometryReader { geo in
                let origen = geo.frame(in: .global).origin
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.04)
                        .contentShape(Rectangle())
                        .onContinuousHover { fase in
                            if case .active = fase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
                        }
                    if let r = rectangulo {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: 0.04, green: 0.52, blue: 1).opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color(red: 0.04, green: 0.52, blue: 1), lineWidth: 2))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .allowsHitTesting(false)
                    }
                    Text("Arrastra para señalar · Esc para salir")
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 56)
                        .allowsHitTesting(false)
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { valor in
                            if inicio == nil { inicio = valor.startLocation }
                            actual = valor.location
                        }
                        .onEnded { _ in
                            guard let r = rectangulo else { return }
                            let global = r.offsetBy(dx: origen.x, dy: origen.y)
                            inicio = nil
                            actual = nil
                            NSCursor.arrow.set()
                            Task { await KurthSenalar.shared.terminarCaja(global, ventana: windowState, bm: browserManager) }
                        }
                )
            }
            .transition(.opacity)
        }
    }

    private var rectangulo: CGRect? {
        guard let a = inicio, let b = actual else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
