// Licensed under GPL-3.0. See LICENSE.
//
//  KurthWorkflowsAviso.swift
//  Nook (rama kurth)
//
//  Lo que se ve mientras se graba un workflow (KurthWorkflows.swift):
//
//   · Sobre la página, abajo al centro, la misma cápsula de vidrio que "Trabajando en esta pestaña"
//     (KurthCabezaAviso), para que la capa hable un solo idioma:
//
//        ( ● Grabando · 0:42 · 7 pasos   🎙   Descartar  [Terminar] )
//
//     El punto es rojo del sistema y respira (Core Animation, sin redibujar la vista); el reloj se
//     actualiza una vez por segundo y solo mientras se graba. Encima, en gris, lo que Kurth está
//     diciendo mientras lo dice: así sabe que el micrófono lo oye sin mirar otro lado.
//
//   · Al tocar Terminar, la cápsula se vuelve la tarjeta del nombre en un solo movimiento: las dos
//     son la misma pieza de vidrio (glassEffectID dentro de un GlassEffectContainer), así que el
//     sistema la estira de cápsula a tarjeta en vez de quitar una y poner otra.
//
//   · En el panel del agente, sobre la caja, los últimos pasos captados, una línea gris cada uno
//     (KurthWorkflowsEnVivo): para ver que se está grabando lo que uno hace.
//

import SwiftUI
import NookDesign
import NookUI
import NookWeb

struct KurthWorkflowsAviso: View {
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var vidrio

    var body: some View {
        let w = KurthWorkflows.shared
        let g = w.grabacion?.ventana == windowState.id ? w.grabacion : nil
        ZStack(alignment: .bottom) {
            if let g {
                GlassEffectContainer {
                    if g.fase == .nombrando {
                        TarjetaDeNombre(grabacion: g, vidrio: vidrio)
                    } else {
                        CapsulaDeGrabacion(grabacion: g, vidrio: vidrio)
                    }
                }
                .padding(.bottom, NookDesign.Spacing.xl)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(reduceMotion ? KurthMotion.reduced : NookDesign.Motion.spring, value: g?.fase)
        .animation(reduceMotion ? KurthMotion.reduced : NookDesign.Motion.spring, value: g == nil)
    }
}

// MARK: - La cápsula

private struct CapsulaDeGrabacion: View {
    let grabacion: KurthWorkflows.Grabacion
    let vidrio: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmaDescartar = false

    private var voz: KurthWorkflowsVoz { KurthWorkflows.shared.voz }

    var body: some View {
        VStack(spacing: 6) {
            // Lo que se está diciendo, o por qué el micrófono no oye.
            if let linea = voz.error ?? (voz.parcial.isEmpty ? nil : voz.parcial) {
                Text(linea)
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 360)
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .symbolEffect(.breathe.pulse, options: .repeating, isActive: !reduceMotion)
                    .accessibilityHidden(true)
                TimelineView(.periodic(from: grabacion.inicio, by: 1)) { reloj in
                    Text("Grabando · \(KurthWorkflowsModelo.minutos(grabacion.duracion(reloj.date))) · \(grabacion.acciones) \(grabacion.acciones == 1 ? "paso" : "pasos")")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(NookDesign.Font.secondary)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
                botonMicrofono
                Button(confirmaDescartar ? "¿Descartar?" : "Descartar") {
                    if confirmaDescartar || grabacion.acciones < 3 {
                        KurthWorkflows.shared.descartar()
                    } else {
                        confirmaDescartar = true
                    }
                }
                .buttonStyle(.plain)
                .font(NookDesign.Font.secondary)
                .foregroundStyle(confirmaDescartar ? Color(nsColor: .systemRed) : .secondary)
                .help("Tira la grabación sin guardar nada")
                .task(id: confirmaDescartar) {
                    // La confirmación se retira sola si no se toca.
                    guard confirmaDescartar else { return }
                    try? await Task.sleep(for: .seconds(3))
                    confirmaDescartar = false
                }
                KurthBotonDeCapsula(titulo: "Terminar") {
                    Task { await KurthWorkflows.shared.terminar() }
                }
                .help("Termina y ponle nombre")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: KurthTopBarView.capsuleHeight)
            .glassEffect(.regular, in: Capsule())
            .glassEffectID("grabadora", in: vidrio)
            .nookElevation(.floating)
        }
        .animation(NookDesign.Motion.quick, value: voz.parcial.isEmpty)
        .animation(NookDesign.Motion.quick, value: confirmaDescartar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Grabando un workflow")
    }

    private var botonMicrofono: some View {
        let encendido = voz.encendida
        return Button {
            KurthWorkflows.shared.alternarVoz()
        } label: {
            Image(systemName: encendido ? "mic.fill" : "mic.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(encendido ? Color.primary : Color.secondary)
                .frame(width: KurthTopBarView.capsuleHeight - 8, height: KurthTopBarView.capsuleHeight - 8)
                .background(Circle().fill(.primary.opacity(encendido ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(encendido ? "Micrófono encendido: lo que dices se guarda con los pasos (se transcribe en la Mac). Toca para apagarlo."
              : "Micrófono apagado. Toca para narrar mientras grabas; también puedes escribir en la caja del agente.")
        .accessibilityLabel(encendido ? "Apagar micrófono" : "Encender micrófono")
    }
}

/// Un botón dentro de una cápsula de vidrio: relleno propio concéntrico (4 pt de aire), como Detener.
struct KurthBotonDeCapsula: View {
    let titulo: String
    var enfatizado = false
    let accion: () -> Void
    @State private var encima = false

    var body: some View {
        Button(action: accion) {
            Text(titulo)
                .font(NookDesign.Font.secondary)
                .foregroundStyle(enfatizado ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: KurthTopBarView.capsuleHeight - 8)
                .background(Capsule().fill(enfatizado ? AnyShapeStyle(Color.accentColor.opacity(encima ? 0.9 : 1))
                                                      : AnyShapeStyle(HierarchicalShapeStyle.primary.opacity(encima ? 0.14 : 0.08))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHoverTracking { encima = $0 }
        .animation(NookDesign.Motion.quick, value: encima)
    }
}

// MARK: - La tarjeta del nombre

private struct TarjetaDeNombre: View {
    let grabacion: KurthWorkflows.Grabacion
    let vidrio: Namespace.ID
    @State private var titulo = ""
    @State private var descripcion = ""
    @State private var problema: String?
    @FocusState private var enNombre: Bool

    private var existente: KurthWorkflow? {
        grabacion.reemplaza.flatMap { KurthWorkflows.shared.workflow($0) }
    }

    /// Si el nombre corto choca con otro workflow (y no es una regrabación de ese mismo).
    private var choca: Bool {
        guard grabacion.reemplaza == nil else { return false }
        let nombre = KurthGuardarSkill.nombreValido(titulo)
        return !nombre.isEmpty && KurthWorkflows.shared.tienda.existe(nombre)
    }

    private var resumen: String {
        var partes = ["\(grabacion.acciones) \(grabacion.acciones == 1 ? "paso" : "pasos")",
                      KurthWorkflowsModelo.minutos(grabacion.duracion())]
        if grabacion.frases > 0 { partes.append("\(grabacion.frases) \(grabacion.frases == 1 ? "comentario" : "comentarios")") }
        return partes.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(existente.map { "Volver a grabar «\($0.titulo)»" } ?? "Guardar workflow")
                .font(NookDesign.Font.body.weight(.semibold))
            campo("Nombre, p. ej. Reporte semanal de Krei", texto: $titulo)
                .focused($enNombre)
            campo("¿Qué hace? (opcional)", texto: $descripcion)
            Text(problema ?? (choca ? "Ya hay un workflow con ese nombre: se reemplaza." : resumen))
                .font(NookDesign.Font.caption)
                .foregroundStyle(problema != nil || choca ? Color.orange : Color.secondary)
            HStack(spacing: 8) {
                Button("Seguir grabando") { KurthWorkflows.shared.seguirGrabando() }
                    .buttonStyle(.plain)
                    .font(NookDesign.Font.secondary)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                KurthBotonDeCapsula(titulo: "Guardar", enfatizado: true, accion: guardar)
                    .disabled(KurthGuardarSkill.nombreValido(titulo).isEmpty || grabacion.acciones == 0)
                    .opacity(KurthGuardarSkill.nombreValido(titulo).isEmpty || grabacion.acciones == 0 ? 0.5 : 1)
            }
        }
        .padding(14)
        .frame(width: 340)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .glassEffectID("grabadora", in: vidrio)
        .nookElevation(.floating)
        .onAppear {
            titulo = existente?.titulo ?? ""
            descripcion = existente?.descripcion ?? ""
            enNombre = true
        }
    }

    private func campo(_ marcador: String, texto: Binding<String>) -> some View {
        TextField(marcador, text: texto)
            .textFieldStyle(.plain)
            .font(NookDesign.Font.bodyRegular)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onSubmit(guardar)
    }

    private func guardar() {
        guard !KurthGuardarSkill.nombreValido(titulo).isEmpty, grabacion.acciones > 0 else { return }
        do {
            try KurthWorkflows.shared.guardar(titulo: titulo, descripcion: descripcion)
        } catch {
            problema = error.localizedDescription
        }
    }
}

// MARK: - En el panel del agente

/// Los últimos pasos captados, sobre la caja del agente, mientras se graba en esta ventana.
struct KurthWorkflowsEnVivo: View {
    let grabacion: KurthWorkflows.Grabacion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(grabacion.pasos.suffix(5)) { paso in
                HStack(spacing: 6) {
                    Image(systemName: KurthWorkflowsIconos.de(paso.tipo))
                        .font(.system(size: 9, weight: .medium))
                        .frame(width: 12)
                    Text(KurthWorkflowsModelo.lineaCorta(paso))
                        .italic(paso.esNarracion)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if grabacion.pasos.isEmpty {
                Text("Haz la tarea como siempre. Lo que escribas aquí se guarda como nota.")
                    .lineLimit(2)
            }
        }
        .font(.system(size: KurthAgentChat.tamañoDeTexto - 1))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .animation(NookDesign.Motion.standard, value: grabacion.pasos.map(\.id))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pasos grabados")
    }
}

enum KurthWorkflowsIconos {
    static func de(_ tipo: KurthWorkflowPaso.Tipo) -> String {
        switch tipo {
        case .clic: return "cursorarrow.click"
        case .escribir: return "character.cursor.ibeam"
        case .elegir: return "list.bullet"
        case .marcar: return "checkmark.square"
        case .archivo: return "paperclip"
        case .tecla: return "keyboard"
        case .enviar: return "paperplane"
        case .scroll: return "arrow.up.and.down"
        case .navegar: return "globe"
        case .pestañaNueva: return "plus.square.on.square"
        case .cerrarPestaña: return "xmark.square"
        case .cambiarPestaña: return "square.on.square"
        case .space: return "square.stack"
        case .voz: return "quote.opening"
        case .nota: return "text.bubble"
        }
    }
}
