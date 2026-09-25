// Licensed under GPL-3.0. See LICENSE.
//
//  KurthPanelDePagina.swift
//  Nook (rama kurth)
//
//  Lo que se hace con la página, en el panel del botón de al lado del chat (ExtensionLibraryView),
//  que ya tenía Copiar enlace, Copiar título, Silenciar y el zoom (Kurth, 25 sep: "todas las
//  opciones nuevas mételas en el de opciones"):
//  - una segunda fila con Imprimir, PDF y Captura de la página completa (Archivo web quedó solo en
//    el menú Archivo: en el panel no sumaba, Kurth 25 sep); la captura dice dónde quedó;
//  - "Tamaño del texto" junto a "Page Zoom", con el mismo −/%/+.
//  Los mismos botones y filas que ya usa el panel, copiados en su forma (allá son privados).
//

import AppKit
import SwiftUI
import WebKit
import NookDesign
import NookWeb

/// La segunda fila de botones del panel.
struct KurthAccionesDePagina: View {
    let browserManager: BrowserManager
    let windowState: BrowserWindowState
    let onDismiss: () -> Void

    private var pagina: WKWebView? {
        guard let tab = browserManager.tabs.selectedSession(in: windowState) else { return nil }
        return browserManager.getWebView(for: tab.itemID, in: windowState.id) ?? tab.webView
    }

    private var titulo: String { browserManager.tabs.selectedSession(in: windowState)?.title ?? "Página" }

    /// La última captura, para decir dónde quedó: sin esto no se sabía (Kurth, 25 sep).
    @State private var captura: URL?

    var body: some View {
        VStack(spacing: 6) {
        HStack(spacing: 6) {
            KurthBotonDePanel(icono: "printer", texto: "Imprimir") {
                guard let pagina else { return false }
                onDismiss()
                KurthImprimir.imprimir(pagina)
                return false
            }
            KurthBotonDePanel(icono: "doc.richtext", texto: "PDF") {
                guard let pagina else { return false }
                onDismiss()
                KurthImprimir.exportarPDF(pagina, titulo: titulo)
                return false
            }
            KurthBotonDePanel(icono: "camera.viewfinder", texto: "Captura", listo: "Guardada") {
                guard let pagina else { return false }
                let url = await KurthImprimir.capturarPaginaCompleta(pagina, titulo: titulo)
                withAnimation(NookDesign.Motion.quick) { captura = url }
                return url != nil
            }
        }
        .disabled(pagina == nil)

        if let captura {
            // Dónde quedó, con un botón que la abre en Finder ya seleccionada. También quedó copiada.
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                Text("En Descargas y copiada")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Mostrar") { NSWorkspace.shared.activateFileViewerSelecting([captura]) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            .font(NookDesign.Font.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(NookDesign.Surface.fill, in: NookDesign.Radius.shape(NookDesign.Radius.sm))
            .help(captura.lastPathComponent)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        }
    }
}

/// Como el CopyButton del panel: ícono arriba, nombre abajo, relleno gris. Con `listo`, al terminar
/// bien muestra una palomita y ese texto un momento; mientras trabaja, un indicador.
struct KurthBotonDePanel: View {
    let icono: String
    let texto: String
    var listo: String? = nil
    let accion: @MainActor () async -> Bool

    @State private var encima = false
    @State private var trabajando = false
    @State private var hecho = false

    var body: some View {
        Button {
            guard !trabajando else { return }
            trabajando = true
            Task {
                let salio = await accion()
                trabajando = false
                guard salio, listo != nil else { return }
                withAnimation(NookDesign.Motion.quick) { hecho = true }
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(NookDesign.Motion.quick) { hecho = false }
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if trabajando {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: hecho ? "checkmark" : icono)
                            .font(NookDesign.Font.title)
                            .foregroundStyle(hecho ? .green : .primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 28, height: 28)
                Text(hecho ? (listo ?? texto) : texto)
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(hecho ? .green : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(encima ? NookDesign.Surface.fillPressed : NookDesign.Surface.fill)
            .clipShape(NookDesign.Radius.shape(NookDesign.Radius.md))
        }
        .buttonStyle(.plain)
        .onHoverTracking { encima = $0 }
    }
}

/// "Tamaño del texto" con −, porcentaje y +, como la fila de Page Zoom de al lado.
struct KurthFilaTamañoDeTexto: View {
    let browserManager: BrowserManager
    let windowState: BrowserWindowState

    @State private var porcentaje = 100
    @State private var encima = false

    private var pagina: WKWebView? {
        guard let tab = browserManager.tabs.selectedSession(in: windowState) else { return nil }
        return browserManager.getWebView(for: tab.itemID, in: windowState.id) ?? tab.webView
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "textformat.size")
                .font(NookDesign.Font.body)
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(Color.orange.opacity(0.12))
                .clipShape(NookDesign.Radius.shape(NookDesign.Radius.sm))
            Text("Tamaño del texto")
                .font(NookDesign.Font.body)
            Spacer()
            HStack(spacing: 6) {
                paso("minus", mas: false)
                Text("\(porcentaje)%")
                    .font(NookDesign.Font.secondary)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36)
                    .onTapGesture(count: 2) { cambiar(nil) } // doble clic: regresa a 100 %
                paso("plus", mas: true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background(encima ? NookDesign.Surface.fill : Color.clear)
        .clipShape(NookDesign.Radius.shape(NookDesign.Radius.md))
        .onHoverTracking { encima = $0 }
        .onAppear { leer() }
        .help("Solo la letra, sin agrandar la página (⌥⌘+ / ⌥⌘−). Doble clic en el porcentaje: 100 %.")
    }

    private func paso(_ simbolo: String, mas: Bool) -> some View {
        Button { cambiar(mas) } label: {
            Image(systemName: simbolo)
                .font(NookDesign.Font.captionStrong)
                .frame(width: 22, height: 22)
                .background(NookDesign.Surface.fill)
                .clipShape(NookDesign.Radius.shape(NookDesign.Radius.xs))
        }
        .buttonStyle(.plain)
    }

    private func cambiar(_ mas: Bool?) {
        guard let pagina else { return }
        KurthImprimir.tamañoDeTexto(pagina, mas: mas)
        leer()
    }

    private func leer() {
        guard let pagina else { return }
        porcentaje = Int((KurthImprimir.factorDeTexto(pagina) * 100).rounded())
    }
}
