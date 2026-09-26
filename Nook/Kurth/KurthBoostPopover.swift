// Licensed under GPL-3.0. See LICENSE.
//
//  KurthBoostPopover.swift
//  Nook (rama kurth)
//
//  La cara de los Boosts (KurthBoosts.swift): clic derecho en la cápsula del dominio → "Boost para
//  este sitio…" → un popover de una sola superficie: el host con su interruptor, "Describe lo que
//  quieres" (va al agente del panel, que escribe y aplica el código con kurth_boost) y, plegado en
//  "Código", el CSS y el JS en monoespaciada. El CSS se ve en la página mientras se escribe; el JS
//  se aplica con su botón, porque aplicarlo recarga la pestaña.
//  Con un boost encendido, la cápsula lleva un punto junto al host (KurthBoostPunto).
//

import AppKit
import SwiftUI
import NookDesign
import NookWeb

// MARK: - Gancho en la cápsula del dominio

/// Menú de clic derecho y popover sobre la cápsula del dominio (KurthTopBarView.address).
struct KurthBoostAncla: ViewModifier {
    let session: PageSession
    /// Sin menú de clic derecho: en la tira compacta el clic derecho ya es de las pestañas; ahí el
    /// popover solo se abre desde el panel de opciones.
    var conMenu = true
    @Environment(BrowserWindowState.self) private var windowState
    @State private var abierto = false

    func body(content: Content) -> some View {
        let host = KurthBoostsModelo.host(de: session.url)
        conMenuSiToca(content, host: host)
            // Desde el panel de opciones (botón Boost).
            .onChange(of: KurthBoosts.shared.popoverPedido) { _, ventana in
                guard ventana == windowState.id else { return }
                KurthBoosts.shared.popoverAbierto()
                if host != nil { abierto = true }
            }
            .popover(isPresented: $abierto, arrowEdge: .bottom) {
                if let host {
                    KurthBoostPopover(host: host) { pedido in
                        abierto = false
                        KurthBoosts.describir(pedido, host: host, pagina: session, en: windowState)
                    }
                }
            }
    }

    /// El menú de clic derecho solo donde se pide: un contextMenu vacío igual se quedaría el clic
    /// derecho de la tira compacta.
    @ViewBuilder
    private func conMenuSiToca(_ content: Content, host: String?) -> some View {
        if conMenu {
            content.contextMenu {
                // Solo https: en http una red ajena podría hacerse pasar por el sitio y recibir el JS.
                Button("Boost para este sitio…") { abierto = true }
                    .disabled(host == nil)
            }
        } else {
            content
        }
    }
}

/// El punto junto al host: hay boost encendido para esta página. Va en un overlay para que el host
/// no se mueva al aparecer o desaparecer.
struct KurthBoostPunto: View {
    let url: URL
    private var boosts: KurthBoosts { .shared }

    var body: some View {
        let activo = boosts.aplica(en: url)
        Circle()
            .fill(Color.accentColor)
            .frame(width: KurthEscala.pt(5), height: KurthEscala.pt(5))
            .opacity(activo ? 1 : 0)
            .scaleEffect(activo ? 1 : 0.4)
            .animation(NookDesign.Motion.standard, value: activo)
            .help(boosts.boost(para: url)?.nombre.nonEmpty.map { "Boost: \($0)" } ?? "Boost")
            .accessibilityHidden(!activo)
            .allowsHitTesting(activo)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Popover

struct KurthBoostPopover: View {
    let host: String
    let describir: (String) -> Void

    @State private var pedido = ""
    @State private var codigoAbierto = false
    /// El JS que se está escribiendo; se aplica con su botón (recarga).
    @State private var borradorJS = ""
    @State private var errorJS: String?
    @FocusState private var enPedido: Bool

    private let ancho: CGFloat = 340
    /// Unas siete líneas de 11 pt: se ve un bloque de reglas sin que el popover tape media página.
    private let altoDeEditor: CGFloat = 110
    /// El botón de enviar, a la escala del campo (el del chat es de 28 con letra de 13).
    private let enviarLado: CGFloat = 22

    private var tienda: KurthBoosts { .shared }
    private var boost: KurthBoost? { tienda.boosts[host] }
    private var jsSinAplicar: Bool { borradorJS != (boost?.js ?? "") }
    private var puedeDescribir: Bool {
        !pedido.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && KurthBoosts.agentePuedeRecibir()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.lg) {
            encabezado
            campoDescribe
            codigo
        }
        .padding(NookDesign.Spacing.xl)
        .frame(width: ancho)
        .onAppear {
            borradorJS = boost?.js ?? ""
            // Con código ya escrito, el código a la vista; sin él, lo primero es describir.
            codigoAbierto = boost?.vacio == false
            if !codigoAbierto { enPedido = true }
        }
        // El agente cambió el JS por MCP mientras el popover estaba abierto: si aquí no había nada
        // sin aplicar, se toma el suyo.
        .onChange(of: boost?.js ?? "") { anterior, nuevo in
            if borradorJS == anterior { borradorJS = nuevo }
        }
        .animation(NookDesign.Motion.standard, value: codigoAbierto)
    }

    // MARK: Encabezado

    private var encabezado: some View {
        HStack(alignment: .center, spacing: NookDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                Text(host)
                    .font(NookDesign.Font.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let nombre = boost?.nombre, !nombre.isEmpty {
                    Text(nombre)
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Toggle("Boost", isOn: Binding(
                get: { boost?.encendido ?? false },
                set: { valor in _ = try? tienda.guardar(host: host, encendido: valor) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            // Sin boost no hay nada que prender: se enciende solo al escribir o describir.
            .disabled(boost == nil)
        }
    }

    // MARK: Describe

    private var campoDescribe: some View {
        HStack(alignment: .bottom, spacing: NookDesign.Spacing.sm) {
            TextField("Describe lo que quieres", text: $pedido, axis: .vertical)
                .textFieldStyle(.plain)
                .font(NookDesign.Font.bodyRegular)
                .lineLimit(1...4)
                .focused($enPedido)
                .onSubmit(mandar)
                .padding(.vertical, 5)
            Button(action: mandar) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: enviarLado, height: enviarLado)
                    .background(Color.primary.opacity(puedeDescribir ? 0.85 : 0.2), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!puedeDescribir)
            .animation(NookDesign.Motion.quick, value: puedeDescribir)
        }
        .padding(.leading, NookDesign.Spacing.md)
        .padding(.trailing, NookDesign.Spacing.xs)
        .padding(.vertical, NookDesign.Spacing.xs)
        .background(NookDesign.Surface.fill, in: NookDesign.Radius.shape(NookDesign.Radius.lg))
    }

    private func mandar() {
        guard puedeDescribir else { return }
        let texto = pedido
        pedido = ""
        describir(texto)
    }

    // MARK: Código

    private var codigo: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.md) {
            Button {
                codigoAbierto.toggle()
            } label: {
                HStack(spacing: NookDesign.Spacing.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(codigoAbierto ? 90 : 0))
                    Text("Código")
                        .font(NookDesign.Font.captionStrong)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if codigoAbierto {
                etiqueta("CSS")
                KurthEditorDeCodigo(texto: Binding(
                    get: { boost?.css ?? "" },
                    set: { nuevo in _ = try? tienda.guardar(host: host, css: nuevo) }
                ))
                .frame(height: altoDeEditor)
                .background(NookDesign.Surface.fill, in: NookDesign.Radius.shape(NookDesign.Radius.md))

                HStack(spacing: NookDesign.Spacing.xs) {
                    etiqueta("JS")
                    Spacer(minLength: 0)
                    Button(action: aplicarJS) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(jsSinAplicar ? .primary : .tertiary)
                    .disabled(!jsSinAplicar)
                    .help("Aplicar el JS y recargar")
                }
                KurthEditorDeCodigo(texto: $borradorJS)
                    .frame(height: altoDeEditor)
                    .background(NookDesign.Surface.fill, in: NookDesign.Radius.shape(NookDesign.Radius.md))
                if let errorJS {
                    Text(errorJS)
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(NookDesign.Surface.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: borradorJS) { errorJS = nil }
    }

    private func etiqueta(_ texto: String) -> some View {
        Text(texto)
            .font(NookDesign.Font.captionStrong)
            .foregroundStyle(.tertiary)
    }

    private func aplicarJS() {
        do {
            try tienda.guardar(host: host, js: borradorJS)
        } catch {
            errorJS = error.localizedDescription
        }
    }
}

// MARK: - Editor de código

/// NSTextView en monoespaciada sin comillas tipográficas, guiones largos ni autocorrección: con las
/// del sistema, un `content: "x"` de CSS salía con comillas curvas y dejaba de valer. Sin fondo
/// propio: la superficie la pone quien lo usa.
struct KurthEditorDeCodigo: NSViewRepresentable {
    @Binding var texto: String

    func makeCoordinator() -> Coordinador { Coordinador(texto: $texto) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let vista = scroll.documentView as? NSTextView else { return scroll }
        vista.isRichText = false
        vista.importsGraphics = false
        vista.allowsUndo = true
        vista.drawsBackground = false
        vista.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        vista.textColor = .labelColor
        vista.textContainerInset = NSSize(width: 4, height: 6)
        vista.isAutomaticQuoteSubstitutionEnabled = false
        vista.isAutomaticDashSubstitutionEnabled = false
        vista.isAutomaticTextReplacementEnabled = false
        vista.isAutomaticSpellingCorrectionEnabled = false
        vista.isAutomaticLinkDetectionEnabled = false
        vista.isAutomaticDataDetectionEnabled = false
        vista.isContinuousSpellCheckingEnabled = false
        vista.isGrammarCheckingEnabled = false
        vista.smartInsertDeleteEnabled = false
        vista.string = texto
        vista.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.texto = $texto
        // Solo si vino de fuera (el agente por MCP): reescribir mientras se teclea movería el cursor.
        guard let vista = scroll.documentView as? NSTextView, vista.string != texto else { return }
        vista.string = texto
    }

    final class Coordinador: NSObject, NSTextViewDelegate {
        var texto: Binding<String>
        init(texto: Binding<String>) { self.texto = texto }

        func textDidChange(_ aviso: Notification) {
            guard let vista = aviso.object as? NSTextView else { return }
            texto.wrappedValue = vista.string
        }
    }
}
