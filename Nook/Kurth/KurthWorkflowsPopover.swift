// Licensed under GPL-3.0. See LICENSE.
//
//  KurthWorkflowsPopover.swift
//  Nook (rama kurth)
//
//  El botón de Workflows (a la derecha del de captura, arriba de la caja del agente) y su popover.
//  Kurth, 26 sep: "desde ahí se crean, se editan y se ejecutan; no es necesario que se ponga el /".
//
//     Workflows
//     ◉ Grabar nuevo
//     ─────────────────────────────────────────
//     Reporte semanal de Krei        [Ejecutar] ⋯
//     Baja ventas de la semana y las manda…
//     ◷ mañana 9:00 · 26 sep
//
//  Una sola superficie (la del popover), sin tarjetas dentro de tarjetas: las filas se separan por
//  aire y el resaltado del mouse, no por líneas. Tocar la fila abre su detalle (editar, corridas);
//  Ejecutar la corre (si tiene parámetros, primero los pregunta con el valor de la última vez); el
//  menú ⋯ trae Editar, Programar…, Renombrar…, Volver a grabar, Redactar el skill otra vez y Borrar.
//  Todo cambia dentro del mismo popover (lista → detalle → programar), con un "‹ Workflows" arriba
//  para volver, en vez de abrir hojas encima.
//

import SwiftUI
import AppKit
import NookDesign
import NookUI
import NookWeb

// MARK: - El botón

struct KurthWorkflowsBoton: View {
    let control: CGFloat
    @Environment(BrowserWindowState.self) private var windowState
    @EnvironmentObject private var browserManager: BrowserManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(KurthWorkflows.ajuste) private var activo = true
    @State private var abierto = false

    var body: some View {
        if activo {
            let grabando = KurthWorkflows.shared.grabacion?.ventana == windowState.id
            Button { abierto.toggle() } label: {
                // Kurth, 26 sep: "cambia el ícono de workflows". En reposo, un recorrido de un punto a
                // otro (un proceso que se repite), no "grabar"; grabando, el punto rojo que respira.
                Image(systemName: grabando ? "record.circle.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(grabando ? Color(nsColor: .systemRed) : Color.primary.opacity(0.7))
                    .symbolEffect(.breathe.pulse, options: .repeating, isActive: grabando && !reduceMotion)
                    .frame(width: control, height: control)
                    .background(grabando ? Color(nsColor: .systemRed).opacity(0.12) : Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(grabando ? "Grabando un workflow" : "Workflows: graba cómo haces algo y el agente lo repite")
            .accessibilityLabel("Workflows")
            .popover(isPresented: $abierto, arrowEdge: .top) {
                KurthWorkflowsPopover(cerrar: { abierto = false })
                    .environment(windowState)
                    .environmentObject(browserManager)
            }
        }
    }
}

// MARK: - El popover

struct KurthWorkflowsPopover: View {
    let cerrar: () -> Void
    @Environment(BrowserWindowState.self) private var windowState
    @EnvironmentObject private var browserManager: BrowserManager

    enum Pagina: Equatable { case lista, detalle(String), programar(String), correr(String) }
    @State private var pagina: Pagina = .lista
    @State private var renombrando: KurthWorkflow?
    @State private var nuevoTitulo = ""
    @State private var borrando: KurthWorkflow?
    @State private var problema: String?

    private var w: KurthWorkflows { KurthWorkflows.shared }

    var body: some View {
        Group {
            switch pagina {
            case .lista: lista
            case .detalle(let n): KurthWorkflowDetalle(nombre: n, volver: { pagina = .lista }, programar: { pagina = .programar(n) })
            case .programar(let n): KurthWorkflowProgramar(nombre: n, volver: { pagina = .lista })
            case .correr(let n): KurthWorkflowCorrer(nombre: n, volver: { pagina = .lista }, alCorrer: cerrar)
            }
        }
        .frame(width: 320)
        .animation(NookDesign.Motion.standard, value: pagina)
        .onAppear { w.recargar() }
        .alert("Renombrar workflow", isPresented: Binding(get: { renombrando != nil }, set: { if !$0 { renombrando = nil } })) {
            TextField("Nombre", text: $nuevoTitulo)
            Button("Renombrar") {
                guard let wf = renombrando else { return }
                intentar { try w.renombrar(wf.nombre, a: nuevoTitulo) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Si cambia el nombre corto, el agente también mueve su skill.")
        }
        .alert("¿Borrar «\(borrando?.titulo ?? "")»?", isPresented: Binding(get: { borrando != nil }, set: { if !$0 { borrando = nil } })) {
            Button("Borrar", role: .destructive) {
                guard let wf = borrando else { return }
                intentar { try w.borrar(wf.nombre) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borra la grabación y su programación, y se le pide al agente que quite su skill.")
        }
    }

    // MARK: Lista

    private var lista: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Workflows")
                .font(NookDesign.Font.body.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            filaDeGrabar
                .padding(.horizontal, 6)
            if w.workflows.isEmpty {
                Text("Todavía no hay workflows. Haz una tarea como siempre mientras grabas (y dila en voz alta si quieres): el agente la aprende y la repite cuando se lo pidas.")
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(w.workflows) { wf in fila(wf) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let problema {
                Text(problema)
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var filaDeGrabar: some View {
        if let g = w.grabacion {
            let aqui = g.ventana == windowState.id
            HStack(spacing: 8) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemRed))
                TimelineView(.periodic(from: g.inicio, by: 1)) { reloj in
                    Text(aqui ? "Grabando · \(KurthWorkflowsModelo.minutos(g.duracion(reloj.date))) · \(g.acciones) pasos"
                              : "Grabando en otra ventana")
                        .monospacedDigit()
                }
                .font(NookDesign.Font.bodyRegular)
                Spacer(minLength: 8)
                if aqui && g.fase == .grabando {
                    Button("Terminar") {
                        cerrar()
                        Task { await w.terminar() }
                    }
                    .buttonStyle(.plain)
                    .font(NookDesign.Font.secondary)
                    .foregroundStyle(Color.accentColor)
                } else if !aqui {
                    // Si esa ventana se cerró, su aviso ya no existe: desde aquí se puede soltar.
                    Button("Descartar") { w.descartar() }
                        .buttonStyle(.plain)
                        .font(NookDesign.Font.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        } else {
            KurthFilaResaltable {
                intentar {
                    try w.empezar(en: windowState, tabs: browserManager.tabs)
                    cerrar()
                }
            } contenido: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemRed))
                    Text("Grabar nuevo")
                        .font(NookDesign.Font.bodyRegular)
                    Spacer(minLength: 8)
                    Text("clics, campos y tu voz")
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func fila(_ wf: KurthWorkflow) -> some View {
        KurthFilaResaltable { pagina = .detalle(wf.nombre) } contenido: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(wf.titulo)
                            .font(NookDesign.Font.bodyRegular.weight(.medium))
                            .lineLimit(1)
                        if !wf.descripcion.isEmpty {
                            Text(wf.descripcion)
                                .font(NookDesign.Font.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        metadatos(wf)
                    }
                    Spacer(minLength: 6)
                    Button("Ejecutar") { ejecutar(wf) }
                        .buttonStyle(KurthEstiloPildora())
                        .help(wf.parametros.isEmpty ? "Correrlo ahora" : "Correrlo ahora (te pregunta los parámetros)")
                    menu(wf)
                }
                if let saltada = wf.programacion?.saltada {
                    HStack(spacing: 6) {
                        Text("Se saltó la de \(KurthWorkflowsModelo.cuando(saltada))")
                            .foregroundStyle(.orange)
                        Button("Correr ahora") { intentar { try w.atenderSaltada(wf.nombre, correrla: true); cerrar() } }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        Spacer(minLength: 4)
                        Button { intentar { try w.atenderSaltada(wf.nombre, correrla: false) } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Olvidarla")
                    }
                    .font(NookDesign.Font.caption)
                }
            }
        }
    }

    private func metadatos(_ wf: KurthWorkflow) -> some View {
        HStack(spacing: 4) {
            if let p = wf.programacion, p.activa, let proxima = p.proxima {
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .medium))
                Text(KurthWorkflowsModelo.cuando(proxima) + " ·")
            }
            Text(KurthWorkflowsFechas.corta(wf.actualizado))
            if !wf.skillAlDia { Text("· sin skill") }
        }
        .font(NookDesign.Font.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    private func menu(_ wf: KurthWorkflow) -> some View {
        Menu {
            Button("Editar", systemImage: "pencil") { pagina = .detalle(wf.nombre) }
            Button("Programar…", systemImage: "clock") { pagina = .programar(wf.nombre) }
            Button("Renombrar…", systemImage: "character.cursor.ibeam") {
                nuevoTitulo = wf.titulo
                renombrando = wf
            }
            Button("Volver a grabar", systemImage: "record.circle") {
                intentar {
                    try w.empezar(en: windowState, tabs: browserManager.tabs, reemplaza: wf.nombre)
                    cerrar()
                }
            }
            .disabled(w.grabacion != nil)
            Button("Redactar el skill otra vez", systemImage: "arrow.clockwise") {
                intentar { try w.redactarSkill(wf.nombre); cerrar() }
            }
            Divider()
            Button("Borrar…", systemImage: "trash", role: .destructive) { borrando = wf }
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

    private func ejecutar(_ wf: KurthWorkflow) {
        if wf.parametros.isEmpty {
            intentar { try w.correr(wf.nombre, valores: [:], programada: false); cerrar() }
        } else {
            pagina = .correr(wf.nombre)
        }
    }

    private func intentar(_ hacer: () throws -> Void) {
        do {
            problema = nil
            try hacer()
        } catch {
            problema = error.localizedDescription
        }
    }
}

// MARK: - Ejecutar con parámetros

private struct KurthWorkflowCorrer: View {
    let nombre: String
    let volver: () -> Void
    let alCorrer: () -> Void
    @State private var valores: [String: String] = [:]
    @State private var problema: String?

    var body: some View {
        let wf = KurthWorkflows.shared.workflow(nombre)
        VStack(alignment: .leading, spacing: 0) {
            KurthEncabezadoDePagina(titulo: wf?.titulo ?? nombre, volver: volver)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(wf?.parametros ?? []) { p in
                    KurthCampoDeParametro(parametro: p, valor: binding(p.nombre))
                }
                if let problema { Text(problema).font(NookDesign.Font.caption).foregroundStyle(.orange) }
            }
            .padding(14)
            KurthPieDePagina(principal: "Ejecutar", cancelar: volver) {
                do {
                    try KurthWorkflows.shared.correr(nombre, valores: valores, programada: false)
                    alCorrer()
                } catch {
                    problema = error.localizedDescription
                }
            }
        }
        .onAppear {
            guard let wf else { return }
            for p in wf.parametros { valores[p.nombre] = wf.valorInicial(p) }
        }
    }

    private func binding(_ clave: String) -> Binding<String> {
        Binding(get: { valores[clave] ?? "" }, set: { valores[clave] = $0 })
    }
}

// MARK: - Detalle: editar y ver corridas

private struct KurthWorkflowDetalle: View {
    let nombre: String
    let volver: () -> Void
    let programar: () -> Void

    @State private var titulo = ""
    @State private var descripcion = ""
    @State private var instrucciones = ""
    @State private var pedido = ""
    @State private var quitados = Set<UUID>()
    @State private var verTodos = false
    @State private var verSkill = false
    @State private var problema: String?

    private var wf: KurthWorkflow? { KurthWorkflows.shared.workflow(nombre) }

    private var hayCambios: Bool {
        guard let wf else { return false }
        return titulo != wf.titulo || descripcion != wf.descripcion || instrucciones != wf.instrucciones
            || !quitados.isEmpty || !pedido.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KurthEncabezadoDePagina(titulo: "Editar", volver: volver)
            if let wf {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            KurthCampo(marcador: "Nombre", texto: $titulo, fuerte: true)
                            KurthCampo(marcador: "Qué hace, en una línea", texto: $descripcion, lineas: 1...3)
                        }
                        pasos(wf)
                        seccion("Siempre") {
                            KurthCampo(marcador: "Para todas las corridas, p. ej. filtra por la semana pasada",
                                       texto: $instrucciones, lineas: 1...4)
                        }
                        seccion("Pedir un cambio") {
                            KurthCampo(marcador: "Dile al agente qué cambiar del workflow", texto: $pedido, lineas: 1...4)
                        }
                        programacion(wf)
                        corridas(wf)
                        skill
                    }
                    .padding(14)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 440)
                .fixedSize(horizontal: false, vertical: true)
                if let problema {
                    Text(problema).font(NookDesign.Font.caption).foregroundStyle(.orange).padding(.horizontal, 14)
                }
                KurthPieDePagina(principal: "Guardar", cancelar: volver, habilitado: hayCambios, guardar: guardar)
            }
        }
        .onAppear {
            guard let wf else { return }
            titulo = wf.titulo
            descripcion = wf.descripcion
            instrucciones = wf.instrucciones
        }
    }

    private func guardar() {
        do {
            try KurthWorkflows.shared.editar(nombre, titulo: titulo, descripcion: descripcion, instrucciones: instrucciones,
                                             quitar: quitados, pedido: pedido)
            volver()
        } catch {
            problema = error.localizedDescription
        }
    }

    private func pasos(_ wf: KurthWorkflow) -> some View {
        let todos = wf.pasos
        let visibles = verTodos ? todos : Array(todos.prefix(8))
        return seccion("Pasos · \(wf.acciones)") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(visibles) { p in
                    let quitado = quitados.contains(p.id)
                    HStack(spacing: 6) {
                        Text(KurthWorkflowsModelo.minutos(p.t))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .frame(width: 30, alignment: .leading)
                        Image(systemName: KurthWorkflowsIconos.de(p.tipo))
                            .font(.system(size: 9, weight: .medium))
                            .frame(width: 12)
                        Text(KurthWorkflowsModelo.lineaCorta(p))
                            .italic(p.esNarracion)
                            .strikethrough(quitado)
                            .lineLimit(2)
                            .help(KurthWorkflowsModelo.linea(p))
                        Spacer(minLength: 4)
                        Button {
                            if quitado { quitados.remove(p.id) } else { quitados.insert(p.id) }
                        } label: {
                            Image(systemName: quitado ? "arrow.uturn.backward" : "minus.circle")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help(quitado ? "Dejarlo" : "Quitar este paso")
                    }
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(quitado ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                }
                if todos.count > visibles.count {
                    Button("Ver los \(todos.count)") { verTodos = true }
                        .buttonStyle(.plain)
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    @ViewBuilder
    private func programacion(_ wf: KurthWorkflow) -> some View {
        seccion("Programado") {
            HStack(spacing: 6) {
                if let p = wf.programacion, p.activa {
                    Image(systemName: "clock").font(.system(size: 10))
                    Text(KurthWorkflowsModelo.describir(p) + (p.proxima.map { " · próxima \(KurthWorkflowsModelo.cuando($0))" } ?? ""))
                        .lineLimit(2)
                } else {
                    Text("No")
                }
                Spacer(minLength: 4)
                Button(wf.programacion?.activa == true ? "Cambiar" : "Programar…", action: programar)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            .font(NookDesign.Font.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func corridas(_ wf: KurthWorkflow) -> some View {
        if !wf.corridas.isEmpty {
            seccion("Corridas") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(wf.corridas.suffix(5).reversed()) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: Self.icono(c.estado))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Self.color(c.estado))
                                .frame(width: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(KurthWorkflowsModelo.cuando(c.inicio)
                                     + (c.fin.map { " · " + KurthWorkflowsModelo.minutos($0.timeIntervalSince(c.inicio)) } ?? "")
                                     + " · " + c.estado.rawValue + (c.programada ? " · programada" : ""))
                                if let r = c.resumen, !r.isEmpty {
                                    Text(r).foregroundStyle(.tertiary).lineLimit(2)
                                }
                            }
                        }
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private static func icono(_ e: KurthWorkflowCorrida.Estado) -> String {
        switch e {
        case .corriendo: return "circle.dotted"
        case .esperando: return "hand.raised"
        case .termino: return "checkmark"
        case .fallo: return "exclamationmark"
        case .saltada: return "moon.zzz"
        }
    }

    private static func color(_ e: KurthWorkflowCorrida.Estado) -> Color {
        switch e {
        case .fallo: return .orange
        case .esperando: return .accentColor
        default: return .secondary
        }
    }

    @ViewBuilder
    private var skill: some View {
        if let texto = KurthWorkflows.shared.textoDelSkill(nombre) {
            DisclosureGroup(isExpanded: $verSkill) {
                ScrollView {
                    Text(texto)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            } label: {
                Text("Ver el skill").font(NookDesign.Font.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("El agente todavía no escribe su skill; Ejecutar sigue la grabación mientras tanto.")
                .font(NookDesign.Font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func seccion<Contenido: View>(_ titulo: String, @ViewBuilder _ contenido: () -> Contenido) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titulo)
                .font(NookDesign.Font.captionStrong)
                .foregroundStyle(.secondary)
            contenido()
        }
    }
}

// MARK: - Programar

private struct KurthWorkflowProgramar: View {
    let nombre: String
    let volver: () -> Void

    @State private var frecuencia: KurthWorkflowProgramacion.Frecuencia = .diario
    @State private var fecha = Date().addingTimeInterval(3600)
    @State private var hora = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var dias: Set<Int> = [2, 3, 4, 5, 6]
    @State private var cadaHoras = 4
    @State private var valores: [String: String] = [:]
    @State private var problema: String?

    private var wf: KurthWorkflow? { KurthWorkflows.shared.workflow(nombre) }

    private var regla: KurthWorkflowProgramacion {
        var p = KurthWorkflowProgramacion(frecuencia: frecuencia)
        let c = Calendar.current.dateComponents([.hour, .minute], from: hora)
        p.hora = c.hour ?? 9
        p.minuto = c.minute ?? 0
        p.fecha = fecha
        p.dias = Array(dias).sorted()
        p.cadaHoras = cadaHoras
        p.desde = Date()
        p.valores = valores
        return p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KurthEncabezadoDePagina(titulo: "Programar", volver: volver)
            VStack(alignment: .leading, spacing: 12) {
                Picker("Frecuencia", selection: $frecuencia) {
                    Text("Una vez").tag(KurthWorkflowProgramacion.Frecuencia.unaVez)
                    Text("Diario").tag(KurthWorkflowProgramacion.Frecuencia.diario)
                    Text("Días").tag(KurthWorkflowProgramacion.Frecuencia.dias)
                    Text("Cada N h").tag(KurthWorkflowProgramacion.Frecuencia.cadaHoras)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch frecuencia {
                case .unaVez:
                    DatePicker("Cuándo", selection: $fecha, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field)
                case .diario:
                    DatePicker("A las", selection: $hora, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                case .dias:
                    selectorDeDias
                    DatePicker("A las", selection: $hora, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                case .cadaHoras:
                    Stepper("Cada \(cadaHoras) \(cadaHoras == 1 ? "hora" : "horas")", value: $cadaHoras, in: 1...24)
                }

                ForEach(wf?.parametros ?? []) { p in
                    KurthCampoDeParametro(parametro: p, valor: Binding(get: { valores[p.nombre] ?? "" },
                                                                        set: { valores[p.nombre] = $0 }))
                }

                Text(regla.siguiente(despuesDe: Date()).map { "Próxima: " + KurthWorkflowsModelo.cuando($0) } ?? "Esa hora ya pasó")
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
                Text("Corre en una pestaña propia del agente, en segundo plano. Si a esa hora Nook está cerrado o la Mac dormida, no se corre sola: te avisa para que la corras.")
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !KurthWorkflows.programadosActivos {
                    Text("Lo programado está en pausa (kurth.workflowsProgramados).")
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.orange)
                }
                if let problema { Text(problema).font(NookDesign.Font.caption).foregroundStyle(.orange) }
            }
            .font(NookDesign.Font.bodyRegular)
            .padding(14)
            KurthPieDePagina(principal: "Programar", cancelar: volver,
                             habilitado: frecuencia != .dias || !dias.isEmpty,
                             secundario: wf?.programacion == nil ? nil : ("Quitar", {
                                 do { try KurthWorkflows.shared.desprogramar(nombre); volver() } catch { problema = error.localizedDescription }
                             })) {
                do {
                    try KurthWorkflows.shared.programar(nombre, regla)
                    volver()
                } catch {
                    problema = error.localizedDescription
                }
            }
        }
        .onAppear(perform: cargar)
    }

    private var selectorDeDias: some View {
        HStack(spacing: 6) {
            ForEach([(2, "L"), (3, "M"), (4, "M"), (5, "J"), (6, "V"), (7, "S"), (1, "D")], id: \.0) { dia, letra in
                let elegido = dias.contains(dia)
                Button {
                    if elegido { dias.remove(dia) } else { dias.insert(dia) }
                } label: {
                    Text(letra)
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(elegido ? Color.white : Color.primary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(elegido ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.primary.opacity(0.06))))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func cargar() {
        guard let wf else { return }
        for p in wf.parametros { valores[p.nombre] = wf.programacion?.valores[p.nombre] ?? wf.valorInicial(p) }
        guard let p = wf.programacion else { return }
        frecuencia = p.frecuencia
        if let f = p.fecha { fecha = f }
        hora = Calendar.current.date(bySettingHour: p.hora, minute: p.minuto, second: 0, of: Date()) ?? hora
        if !p.dias.isEmpty { dias = Set(p.dias) }
        cadaHoras = p.cadaHoras
    }
}

// MARK: - Piezas compartidas

/// "‹ Workflows" y el título de la página.
private struct KurthEncabezadoDePagina: View {
    let titulo: String
    let volver: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: volver) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Volver a Workflows")
            .keyboardShortcut(.cancelAction)
            Text(titulo)
                .font(NookDesign.Font.body.weight(.semibold))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }
}

/// Cancelar a la izquierda de la acción principal, abajo; una acción secundaria (Quitar) a la izquierda.
private struct KurthPieDePagina: View {
    let principal: String
    let cancelar: () -> Void
    var habilitado = true
    var secundario: (String, () -> Void)? = nil
    let guardar: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let s = secundario {
                Button(s.0, action: s.1)
                    .buttonStyle(.plain)
                    .font(NookDesign.Font.secondary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancelar", action: cancelar)
                .buttonStyle(.plain)
                .font(NookDesign.Font.secondary)
                .foregroundStyle(.secondary)
            Button(principal, action: guardar)
                .buttonStyle(KurthEstiloPildora(enfatizado: true))
                .disabled(!habilitado)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Un campo con el mismo relleno gris de los controles de la caja del agente.
private struct KurthCampo: View {
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

private struct KurthCampoDeParametro: View {
    let parametro: KurthWorkflowParametro
    @Binding var valor: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(parametro.descripcion.isEmpty ? parametro.nombre : parametro.descripcion)
                .font(NookDesign.Font.caption)
                .foregroundStyle(.secondary)
            KurthCampo(marcador: parametro.ejemplo, texto: $valor)
        }
    }
}

/// Una fila que se resalta con el mouse y se toca entera.
private struct KurthFilaResaltable<Contenido: View>: View {
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

/// Botón pastilla: gris de los controles, o con el acento cuando es la acción principal.
private struct KurthEstiloPildora: ButtonStyle {
    var enfatizado = false
    @Environment(\.isEnabled) private var habilitado

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NookDesign.Font.secondary)
            .foregroundStyle(enfatizado ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(enfatizado ? AnyShapeStyle(Color.accentColor)
                                                  : AnyShapeStyle(HierarchicalShapeStyle.primary.opacity(0.08))))
            .opacity(habilitado ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

enum KurthWorkflowsFechas {
    /// "26 sep" (o "hoy"/"ayer") para la fila.
    static func corta(_ fecha: Date, ahora: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(fecha) { return "hoy" }
        if cal.isDateInYesterday(fecha) { return "ayer" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.setLocalizedDateFormatFromTemplate(cal.isDate(fecha, equalTo: ahora, toGranularity: .year) ? "d MMM" : "d MMM yyyy")
        return f.string(from: fecha).replacingOccurrences(of: ".", with: "")
    }
}
