// Licensed under GPL-3.0. See LICENSE.
//
//  KurthMemoriasPopover.swift
//  Nook (rama kurth)
//
//  El popover del botón de Workflows con dos pestañas arriba, "Workflows | Memorias", en una sola
//  superficie (Kurth, 26 sep: "deben estar unificados tanto workflows como memorias"). La pestaña
//  Workflows es la misma de siempre (KurthWorkflowsPopover); aquí solo va el control y la de Memorias:
//
//     [ Workflows | Memorias ]
//     ⊕ Nueva memoria
//     🔍 Buscar
//     Google Ads · Ultrafemme                      ⋯
//     Cuenta 123-456-7890 bajo el MCC…
//     ✦ ads.google.com · Ultrafemme
//
//  Mismo criterio que Workflows: las filas se separan por aire y el resaltado del mouse, no por líneas;
//  tocar la fila la abre para editar dentro del mismo popover (con "‹" para volver), sin hojas encima.
//  El control segmentado solo está en la raíz de cada pestaña: en editar se ve lo que se edita.
//
//  Las piezas visuales (fila resaltable, campo, pastilla, encabezado y pie) repiten las de
//  KurthWorkflowsPopover, que son privadas de ese archivo; se unifican cuando las dos ramas se junten.
//

import SwiftUI
import AppKit
import NookDesign
import NookUI

// MARK: - Las dos pestañas

struct KurthWorkflowsYMemorias: View {
    let cerrar: () -> Void
    @AppStorage(KurthMemorias.ajuste) private var memoriasActivas = true
    /// Se recuerda mientras Nook está abierto: si Kurth anda curando memorias, reabrir no lo regresa.
    @State private var seccion = KurthWorkflowsYMemorias.ultima

    enum Seccion: Hashable { case workflows, memorias }
    @MainActor private static var ultima: Seccion = .workflows

    var body: some View {
        if !memoriasActivas {
            KurthWorkflowsPopover(cerrar: cerrar)
        } else {
            Group {
                switch seccion {
                case .workflows: KurthWorkflowsPopover(cerrar: cerrar, titulo: AnyView(selector))
                case .memorias: KurthMemoriasVista(selector: AnyView(selector))
                }
            }
            .onChange(of: seccion) { _, nueva in Self.ultima = nueva }
        }
    }

    private var selector: some View {
        Picker("Sección", selection: $seccion) {
            Text("Workflows").tag(Seccion.workflows)
            Text("Memorias").tag(Seccion.memorias)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Memorias

struct KurthMemoriasVista: View {
    let selector: AnyView

    enum Pagina: Equatable {
        case lista
        /// nil = nueva.
        case editar(String?)
    }

    @State private var pagina: Pagina = .lista
    @State private var busqueda = ""
    @State private var borrando: KurthMemoria?

    private var m: KurthMemorias { KurthMemorias.shared }

    var body: some View {
        Group {
            switch pagina {
            case .lista: lista
            case .editar(let id): KurthMemoriaEditor(id: id, volver: { pagina = .lista })
            }
        }
        .frame(width: 320)
        .animation(NookDesign.Motion.standard, value: pagina)
        .onAppear { m.recargar() }
        .alert("¿Borrar «\(borrando?.titulo ?? "")»?", isPresented: Binding(get: { borrando != nil }, set: { if !$0 { borrando = nil } })) {
            Button("Borrar", role: .destructive) {
                if let b = borrando { m.borrar(b.id) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Ningún agente la vuelve a ver. Si es un dato que cambió, mejor edítala.")
        }
    }

    private var visibles: [KurthMemoria] {
        let q = busqueda.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return m.vivas }
        // La misma búsqueda que usa el agente, más lo que empiece igual en el título mientras se escribe.
        let porRelevancia = KurthMemoriasModelo.buscar(m.memorias, texto: q, host: q.contains(".") ? q : nil).map(\.memoria)
        let n = KurthMemoriasModelo.normal(q)
        let porTitulo = m.vivas.filter { KurthMemoriasModelo.normal($0.titulo).contains(n) && !porRelevancia.contains($0) }
        return porRelevancia + porTitulo
    }

    // MARK: Lista

    private var lista: some View {
        VStack(alignment: .leading, spacing: 0) {
            selector
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            KurthMemoriaFila { pagina = .editar(nil) } contenido: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text("Nueva memoria")
                        .font(NookDesign.Font.bodyRegular)
                    Spacer(minLength: 8)
                    Text("lo que el agente debe saber")
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)

            if m.vivas.isEmpty {
                Text("Todavía no hay memorias. El agente guarda aquí lo que aprende navegando (la URL y el id de cada cuenta, dónde está cada reporte, tus filtros) para no preguntarlo otra vez, sea el agente que sea. También puedes escribir una tú.")
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                buscador
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                let filas = visibles
                if filas.isEmpty {
                    Text("Nada con «\(busqueda)».")
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(filas) { memoria in fila(memoria) }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 380)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.bottom, 4)
    }

    /// El borde del campo coincide con el del resaltado de las filas, y la lupa con sus íconos.
    private var buscador: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            TextField("Buscar", text: $busqueda)
                .textFieldStyle(.plain)
                .font(NookDesign.Font.bodyRegular)
            if !busqueda.isEmpty {
                Button { busqueda = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Borrar la búsqueda")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func fila(_ memoria: KurthMemoria) -> some View {
        KurthMemoriaFila { pagina = .editar(memoria.id) } contenido: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(memoria.titulo)
                        .font(NookDesign.Font.bodyRegular.weight(.medium))
                        .lineLimit(1)
                    Text(Self.unaLinea(memoria.contenido))
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    metadatos(memoria)
                }
                Spacer(minLength: 6)
                menu(memoria)
            }
        }
    }

    private func metadatos(_ memoria: KurthMemoria) -> some View {
        HStack(spacing: 4) {
            Image(systemName: Self.icono(memoria.origen))
                .font(.system(size: 9, weight: .medium))
                .help(Self.origen(memoria.origen))
            Text(([memoria.hosts.first ?? memoria.tipo.nombre] + memoria.etiquetas.prefix(2)).joined(separator: " · "))
        }
        .font(NookDesign.Font.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    private func menu(_ memoria: KurthMemoria) -> some View {
        Menu {
            Button("Editar", systemImage: "pencil") { pagina = .editar(memoria.id) }
            Divider()
            Button("Borrar…", systemImage: "trash", role: .destructive) { borrando = memoria }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Más")
    }

    static func unaLinea(_ texto: String) -> String {
        texto.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func icono(_ o: KurthMemoria.Origen) -> String {
        switch o {
        case .agente: return "sparkle"
        case .kurth: return "person.fill"
        case .workflow: return "record.circle"
        }
    }

    static func origen(_ o: KurthMemoria.Origen) -> String {
        switch o {
        case .agente: return "La aprendió un agente"
        case .kurth: return "La escribiste tú"
        case .workflow: return "Salió de un workflow"
        }
    }
}

// MARK: - Editar o crear

private struct KurthMemoriaEditor: View {
    let id: String?
    let volver: () -> Void

    @State private var titulo = ""
    @State private var contenido = ""
    @State private var sitios = ""
    @State private var etiquetas = ""
    @State private var tipo: KurthMemoria.Tipo = .dato
    @State private var problema: String?
    @State private var confirmarBorrar = false

    private var memoria: KurthMemoria? { id.flatMap { i in KurthMemorias.shared.memorias.first { $0.id == i && $0.viva } } }

    private var hayCambios: Bool {
        let t = titulo.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = contenido.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !c.isEmpty else { return false }
        guard let m = memoria else { return true }
        return t != m.titulo || c != m.contenido || tipo != m.tipo
            || Self.lista(sitios) != m.hosts || Self.lista(etiquetas) != m.etiquetas
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            encabezado
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        KurthMemoriaCampo(marcador: "Título corto: Google Ads · Ultrafemme", texto: $titulo, fuerte: true)
                        KurthMemoriaCampo(marcador: "El dato: la URL, el id de la cuenta, dónde está el reporte…",
                                          texto: $contenido, lineas: 3...8)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        KurthMemoriaCampo(marcador: "Sitio: ads.google.com", texto: $sitios)
                        KurthMemoriaCampo(marcador: "Etiquetas: Ultrafemme, Krei…", texto: $etiquetas)
                    }
                    HStack(spacing: 8) {
                        Text("Tipo")
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.secondary)
                        Picker("Tipo", selection: $tipo) {
                            ForEach(KurthMemoria.Tipo.allCases, id: \.self) { Text($0.nombre).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                    }
                    Text(pie)
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let problema {
                        Text(problema)
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            pieDeBotones
        }
        .onAppear(perform: cargar)
        .alert("¿Borrar «\(memoria?.titulo ?? "")»?", isPresented: $confirmarBorrar) {
            Button("Borrar", role: .destructive) {
                if let id { KurthMemorias.shared.borrar(id) }
                volver()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Ningún agente la vuelve a ver.")
        }
    }

    private var encabezado: some View {
        HStack(spacing: 6) {
            Button(action: volver) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Volver a Memorias")
            .keyboardShortcut(.cancelAction)
            Text(memoria == nil ? "Nueva memoria" : "Editar memoria")
                .font(NookDesign.Font.body.weight(.semibold))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    /// De dónde viene y cuánto se ha usado; en una nueva, la regla de lo que no se guarda.
    private var pie: String {
        guard let m = memoria else {
            return "Sin contraseñas, tokens, códigos ni tarjetas: se rechazan. Guarda dónde vive la credencial, no su valor."
        }
        var partes = [KurthMemoriasVista.origen(m.origen), "creada " + KurthWorkflowsFechas.corta(m.creada)]
        if m.actualizada.timeIntervalSince(m.creada) > 60 { partes.append("editada " + KurthWorkflowsFechas.corta(m.actualizada)) }
        if m.vecesUsada > 0 { partes.append("usada \(m.vecesUsada) \(m.vecesUsada == 1 ? "vez" : "veces")") }
        return partes.joined(separator: " · ")
    }

    private var pieDeBotones: some View {
        HStack(spacing: 12) {
            if memoria != nil {
                Button("Borrar") { confirmarBorrar = true }
                    .buttonStyle(.plain)
                    .font(NookDesign.Font.secondary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancelar", action: volver)
                .buttonStyle(.plain)
                .font(NookDesign.Font.secondary)
                .foregroundStyle(.secondary)
            Button("Guardar", action: guardar)
                .buttonStyle(KurthMemoriaPildora())
                .disabled(!hayCambios)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func cargar() {
        guard let m = memoria else { return }
        titulo = m.titulo
        contenido = m.contenido
        sitios = m.hosts.joined(separator: ", ")
        etiquetas = m.etiquetas.joined(separator: ", ")
        tipo = m.tipo
    }

    /// Lo que Kurth escribe o edita queda como suyo (origen kurth): el agente ya no le cambia el título.
    private func guardar() {
        let entrada = KurthMemoriaEntrada(id: memoria?.id, titulo: titulo, contenido: contenido, tipo: tipo,
                                          hosts: Self.lista(sitios), etiquetas: Self.lista(etiquetas), origen: .kurth)
        do {
            try KurthMemorias.shared.guardar(entrada)
            volver()
        } catch {
            problema = error.localizedDescription
        }
    }

    static func lista(_ texto: String) -> [String] {
        texto.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Piezas (las mismas de KurthWorkflowsPopover)

private struct KurthMemoriaFila<Contenido: View>: View {
    let accion: () -> Void
    @ViewBuilder let contenido: () -> Contenido
    @State private var encima = false

    var body: some View {
        contenido()
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(encima ? 0.06 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onTapGesture(perform: accion)
            .onHoverTracking { encima = $0 }
            .animation(NookDesign.Motion.quick, value: encima)
    }
}

private struct KurthMemoriaCampo: View {
    let marcador: String
    @Binding var texto: String
    var fuerte = false
    var lineas: ClosedRange<Int> = 1...1

    var body: some View {
        TextField(marcador, text: $texto, axis: lineas.upperBound > 1 ? .vertical : .horizontal)
            .textFieldStyle(.plain)
            .font(fuerte ? NookDesign.Font.bodyRegular.weight(.semibold) : NookDesign.Font.bodyRegular)
            .lineLimit(lineas)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct KurthMemoriaPildora: ButtonStyle {
    @Environment(\.isEnabled) private var habilitado

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NookDesign.Font.secondary)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(Color.accentColor))
            .opacity(habilitado ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Capsule())
    }
}
