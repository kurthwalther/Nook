// Licensed under GPL-3.0. See LICENSE.
//
//  KurthWorkflowsReplayVista.swift
//  Nook (rama kurth)
//
//  Las corridas en el detalle de un workflow (popover de Workflows), con el registro del replay
//  exacto (KurthWorkflowsReplay.swift). Kurth tiene que ver si un paso se encontró igual que en la
//  grabación o "parecido", y en ese caso qué cambió en la página, para decidir si el workflow se
//  queda con el nombre nuevo:
//
//     Corridas
//     ✓ hoy 9:00 · 0:12 · terminó · programada
//       11 de 11 pasos · 1 cambió en la página
//       Paso 7 · Cambió de «Descargar informe» a «Descargar reporte»
//       Actualizar el workflow con esto
//       Ver los 11 pasos ›
//
//  Mismo lenguaje que el resto del popover: una sola superficie, texto en roles (.secondary,
//  .tertiary), naranja solo para lo que pide atención (un cambio, un fallo), sin tarjetas dentro.
//

import SwiftUI
import NookDesign

struct KurthWorkflowCorridas: View {
    let wf: KurthWorkflow
    @State private var abierta: UUID?
    @State private var problema: String?

    private var replay: KurthWorkflowsReplay { KurthWorkflowsReplay.shared }

    var body: some View {
        if !wf.corridas.isEmpty || replay.corre(wf.nombre) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Corridas")
                    .font(NookDesign.Font.captionStrong)
                    .foregroundStyle(.secondary)
                if let p = replay.corriendo[wf.nombre] { enCurso(p) }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(wf.corridas.suffix(5).reversed()) { c in
                        if replay.corriendo[wf.nombre]?.corrida != c.id { corrida(c) }
                    }
                }
                if let problema {
                    Text(problema).font(NookDesign.Font.caption).foregroundStyle(.orange)
                }
            }
            .animation(NookDesign.Motion.standard, value: abierta)
        }
    }

    // MARK: En curso

    private func enCurso(_ p: KurthWorkflowsReplay.Progreso) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 9, weight: .semibold))
                .symbolEffect(.rotate, options: .repeating)
                .frame(width: 12)
            Text("Corriendo · paso \(p.paso) de \(p.total)" + (p.nota.map { " · \($0)" } ?? ""))
                .monospacedDigit()
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Detener") { replay.detener(wf.nombre) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .font(NookDesign.Font.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Una corrida

    private func corrida(_ c: KurthWorkflowCorrida) -> some View {
        let pasos = c.pasos ?? []
        let cambios = pasos.filter { KurthWorkflowsReplay.aplicable($0) || $0.nivel == .agente }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: Self.icono(c.estado))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Self.color(c.estado))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(KurthWorkflowsModelo.cuando(c.inicio)
                     + (c.fin.map { " · " + KurthWorkflowsModelo.minutos($0.timeIntervalSince(c.inicio)) } ?? "")
                     + " · " + c.estado.rawValue + (c.programada ? " · programada" : ""))
                    .monospacedDigit()
                if let r = c.resumen, !r.isEmpty {
                    Text(r).foregroundStyle(.tertiary).lineLimit(3)
                }
                ForEach(cambios) { r in
                    Text("Paso \(r.indice) · " + (r.nivel == .agente ? "lo resolvió el agente" : (r.frase ?? "se encontró por \(r.nivel.rawValue)")))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                if c.aplicada != true, cambios.contains(where: KurthWorkflowsReplay.aplicable) {
                    Button("Actualizar el workflow con esto") { actualizar(c) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("La próxima corrida busca los nombres de hoy")
                } else if c.aplicada == true {
                    Text("Workflow actualizado con esta corrida").foregroundStyle(.tertiary)
                }
                if !pasos.isEmpty {
                    Button {
                        abierta = abierta == c.id ? nil : c.id
                    } label: {
                        HStack(spacing: 3) {
                            Text(abierta == c.id ? "Ocultar los pasos" : "Ver los \(pasos.count) pasos")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .bold))
                                .rotationEffect(.degrees(abierta == c.id ? 90 : 0))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    if abierta == c.id { registro(pasos) }
                }
            }
        }
        .font(NookDesign.Font.caption)
        .foregroundStyle(.secondary)
    }

    /// Un renglón por paso: número, qué hizo, con qué nivel y cuánto tardó.
    private func registro(_ pasos: [KurthWorkflowPasoCorrida]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(pasos) { r in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(r.indice)")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, alignment: .trailing)
                    Text(r.descripcion)
                        .lineLimit(1)
                        .foregroundStyle(r.ok ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.orange))
                        .help(r.detalle ?? r.descripcion)
                    Spacer(minLength: 4)
                    Text(Self.nivel(r))
                        .monospacedDigit()
                        .foregroundStyle(r.nivel.cambio || !r.ok ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                        .fixedSize()
                }
            }
        }
        .padding(.top, 2)
        .transition(.opacity)
    }

    private func actualizar(_ c: KurthWorkflowCorrida) {
        do {
            problema = nil
            try replay.actualizarWorkflow(wf.nombre, corrida: c.id)
        } catch {
            problema = error.localizedDescription
        }
    }

    // MARK: Texto e íconos

    /// "exacto · 12 ms", "difuso 0.6 · 1.6 s", "no apareció".
    static func nivel(_ r: KurthWorkflowPasoCorrida) -> String {
        if !r.ok { return r.nivel == .ninguno ? "no apareció" : "falló" }
        var s = r.nivel.rawValue
        if let sim = r.similitud, r.nivel == .difuso || r.nivel == .posicion { s += String(format: " %.2f", sim) }
        if r.nivel != .omitido { s += " · " + (r.ms < 1000 ? "\(r.ms) ms" : String(format: "%.1f s", Double(r.ms) / 1000)) }
        return s
    }

    static func icono(_ e: KurthWorkflowCorrida.Estado) -> String {
        switch e {
        case .corriendo: return "circle.dotted"
        case .esperando: return "hand.raised"
        case .termino: return "checkmark"
        case .fallo: return "exclamationmark"
        case .saltada: return "moon.zzz"
        }
    }

    static func color(_ e: KurthWorkflowCorrida.Estado) -> Color {
        switch e {
        case .fallo: return .orange
        case .esperando: return .accentColor
        default: return .secondary
        }
    }
}
