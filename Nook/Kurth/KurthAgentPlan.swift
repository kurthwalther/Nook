// Licensed under GPL-3.0. See LICENSE.
//
//  KurthAgentPlan.swift
//  Nook (rama kurth)
//
//  El plan del agente sobre la caja del panel (modo con cabeza, KurthCabeza.swift). Antes iba al
//  final de la conversación como una tarjeta gris con viñetas y sin estado: no decía en qué paso
//  iba. Ahora es una sola línea, "Paso 2 de 4 · Subiendo la foto", con un anillo de avance; al
//  tocarla se abre ahí mismo la lista con hecho / ahora / pendiente. Sin tarjeta ni fondo propio:
//  vive en el mismo espacio que la caja, que ya es la superficie.
//
//  Se ve mientras el agente trabaja o mientras al plan le falten pasos (p. ej. el agente se detuvo
//  a preguntar antes de publicar). Terminado todo y cerrado el turno, se va: la respuesta ya lo dice.
//

import SwiftUI
import NookDesign

struct KurthAgentPlan: View {
    let pasos: [KurthACPPlanEntry]
    let trabajando: Bool

    @State private var abierto = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hechos: Int { pasos.filter(\.hecho).count }

    /// El paso en curso; si ninguno lo está, el primero sin hacer.
    private var actual: Int? {
        pasos.firstIndex(where: \.enCurso) ?? pasos.firstIndex { !$0.hecho }
    }

    private var resumen: String {
        guard let actual else { return "Plan completo · \(pasos.count) pasos" }
        return "Paso \(actual + 1) de \(pasos.count) · \(pasos[actual].content)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? KurthMotion.reduced : NookDesign.Motion.standard) { abierto.toggle() }
            } label: {
                HStack(spacing: 7) {
                    avance
                    Text(resumen)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(abierto ? 180 : 0))
                }
                .font(.system(size: KurthAgentChat.tamañoDeTexto - 1, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(abierto ? "Ocultar los pasos" : "Ver todos los pasos")
            .accessibilityLabel(resumen)
            .accessibilityHint(abierto ? "Oculta los pasos" : "Muestra todos los pasos")

            if abierto {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(pasos.enumerated()), id: \.offset) { i, paso in
                        fila(paso, esActual: i == actual)
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .animation(reduceMotion ? KurthMotion.reduced : NookDesign.Motion.standard, value: pasos)
    }

    /// Anillo de avance de 11 pt: la parte hecha en color de acento sobre un aro tenue.
    private var avance: some View {
        let fraccion = pasos.isEmpty ? 0 : CGFloat(hechos) / CGFloat(pasos.count)
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.14), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: fraccion)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .accessibilityHidden(true)
    }

    private func fila(_ paso: KurthACPPlanEntry, esActual: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            ZStack {
                if paso.hecho {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                } else if esActual {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.breathe.pulse, options: .repeating, isActive: trabajando && !reduceMotion)
                } else {
                    Circle()
                        .stroke(Color.primary.opacity(0.25), lineWidth: 1)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 11)
            Text(paso.content)
                .font(.system(size: KurthAgentChat.tamañoDeTexto - 1))
                .foregroundStyle(esActual ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(paso.hecho ? "hecho" : esActual ? "en curso" : "pendiente")
    }
}
