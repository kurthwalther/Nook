// Licensed under GPL-3.0. See LICENSE.
//
//  KurthReglasPopover.swift
//  Nook (rama kurth)
//
//  Reglas de permisos por sitio (Kurth, 26 sep): una lista de hosts exactos con el modo de permisos
//  que toma el agente mientras la pestaña activa esté ahí. Se abre desde el menú de permisos.
//

import SwiftUI
import NookDesign

struct KurthReglasPopover: View {
    /// Los modos que ofrece el agente: (valor, nombre).
    let modos: [(String, String)]
    /// El host de la pestaña activa, para proponerlo al agregar.
    let sugerido: String?

    @State private var reglas = KurthAgentService.reglas
    @State private var nuevoHost = ""
    @State private var nuevoModo = "auto"
    @Environment(\.dismiss) private var cerrar

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reglas por sitio")
                .font(.system(size: 13, weight: .semibold))
            Text("El host se compara exacto y solo en https: netflix.com no cubre www.netflix.com ni netflix.tv. Al salir del sitio vuelve el modo de antes.")
                .font(NookDesign.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(reglas) { regla in
                        HStack(spacing: 8) {
                            Text(regla.host)
                                .font(NookDesign.Font.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Picker("", selection: Binding(
                                get: { regla.modo },
                                set: { valor in
                                    if let i = reglas.firstIndex(of: regla) { reglas[i].modo = valor; guardar() }
                                }
                            )) {
                                ForEach(opciones, id: \.0) { Text($0.1).tag($0.0) }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 118)
                            Button {
                                reglas.removeAll { $0.host == regla.host }
                                guardar()
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Quitar")
                        }
                    }
                    if reglas.isEmpty {
                        Text("Sin reglas.").font(NookDesign.Font.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 220)

            Divider()

            HStack(spacing: 6) {
                TextField(sugerido ?? "host exacto", text: $nuevoHost)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(agregar)
                Picker("", selection: $nuevoModo) {
                    ForEach(opciones, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 118)
                Button("Agregar", action: agregar)
                    .controlSize(.small)
                    .disabled(hostNuevo.isEmpty || reglas.contains { $0.host == hostNuevo })
            }

            HStack {
                Button("Volver a las de fábrica") {
                    reglas = KurthAgentService.reglasPorDefecto
                    guardar()
                }
                .controlSize(.small)
                Spacer()
                Button("Cerrar") { cerrar() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    /// Modos del agente; si aún no hay sesión, los cinco que existen.
    private var opciones: [(String, String)] {
        modos.isEmpty ? [("auto", "Auto"), ("acceptEdits", "Acepta ediciones"), ("bypassPermissions", "Sin permisos"),
                         ("plan", "Plan"), ("default", "Manual")] : modos
    }

    /// Lo escrito o, vacío, el host de la pestaña activa; sin esquema ni ruta, en minúsculas.
    private var hostNuevo: String {
        var t = nuevoHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty { t = sugerido ?? "" }
        if let url = URL(string: t.contains("://") ? t : "https://" + t), let host = url.host() { t = host }
        return t
    }

    private func agregar() {
        let host = hostNuevo
        guard !host.isEmpty, !reglas.contains(where: { $0.host == host }) else { return }
        reglas.append(KurthAgentService.ReglaDeSitio(host: host, modo: nuevoModo))
        nuevoHost = ""
        guardar()
    }

    private func guardar() {
        KurthAgentService.reglas = reglas
    }
}
