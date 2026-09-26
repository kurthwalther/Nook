// Licensed under GPL-3.0. See LICENSE.
//
//  KurthRemotoPopover.swift
//  Nook (rama kurth)
//
//  Lo que sale al tocar el botón del cel en la caja del agente: el QR para la app de Claude del
//  iPhone, el estado mientras conecta, el enlace para abrirlo o copiarlo, y apagar.
//

import AppKit
import SwiftUI
import NookDesign

struct KurthRemotoPopover: View {
    @Environment(KurthAgentService.self) private var agente
    @Environment(\.dismiss) private var cerrar

    private var remoto: KurthRemoto { KurthRemoto.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                Text("Sigue en el cel")
                    .font(.system(size: 13, weight: .semibold))
            }

            contenido

            Text(nota)
                .font(NookDesign.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if remoto.encendido {
                    Button("Apagar") {
                        agente.apagarRemoto()
                        cerrar()
                    }
                } else {
                    Button("Encender") { agente.encenderRemoto() }
                        .disabled(agente.estado == .trabajando || agente.permiso != nil)
                }
                Spacer()
                Button("Cerrar") { cerrar() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 252)
    }

    @ViewBuilder
    private var contenido: some View {
        switch remoto.estado {
        case .apagado:
            Text("Apagado.")
                .font(NookDesign.Font.caption)
                .foregroundStyle(.secondary)

        case .arrancando(let paso):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(paso)
                    .font(NookDesign.Font.caption)
            }

        case .conectado(let url):
            VStack(alignment: .leading, spacing: 8) {
                if let qr = KurthRemoto.qr(url, lado: 200) {
                    Image(nsImage: qr)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 200, height: 200)
                        .padding(6)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: .infinity)
                }
                Text("Escanéalo con la cámara del iPhone: abre esta conversación en la app de Claude.")
                    .font(NookDesign.Font.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Abrir") { NSWorkspace.shared.open(url) }
                    Button("Copiar enlace") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
                .controlSize(.small)
            }

        case .error(let motivo):
            Text("⚠️ " + motivo)
                .font(NookDesign.Font.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nota: String {
        var partes: [String] = []
        if remoto.encendido {
            partes.append("El chat de aquí queda pausado y Nook mantiene la Mac despierta mientras está encendido.")
            if !remoto.conMCP {
                partes.append("Browser Control está apagado (Ajustes › AI), así que desde el cel el agente no podrá manejar Nook.")
            }
        } else {
            partes.append("Abre esta misma conversación en tu iPhone; el agente sigue corriendo en esta Mac.")
        }
        return partes.joined(separator: " ")
    }
}
