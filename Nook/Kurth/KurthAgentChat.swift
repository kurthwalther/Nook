// Licensed under GPL-3.0. See LICENSE.
//
//  KurthAgentChat.swift
//  Nook (rama kurth)
//
//  El panel lateral cuando quien contesta es el agente de línea de comandos (KurthAgentService).
//  Sustituye a SidebarAIChat, que hablaba con APIs de pago por token.
//
//  Decisiones de la interfaz, y por qué:
//   · El texto se pinta mientras llega. El panel anterior guardaba la respuesta y la soltaba
//     entera al final, así que parecía colgado durante varios segundos.
//   · Cada herramienta queda escrita en la conversación con su estado. Antes se veía un
//     "Using X…" que desaparecía, y no quedaba rastro de qué tocó el agente.
//   · El permiso es una tarjeta dentro del chat, en el sitio donde ocurrió, y no un cuadro del
//     sistema que congela la ventana. En un navegador esto importa más que en un editor: lo
//     que el agente acaba de leer puede ser una página de un tercero.
//   · Mientras hay un permiso esperando, el agente está detenido. La tarjeta lo dice, para que
//     un turno quieto no se confunda con uno lento.
//

import SwiftUI
import NookDesign
import NookWeb
import NookUI

struct KurthAgentChat: View {
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(KurthAgentService.self) private var agente

    @State private var texto = ""
    @FocusState private var escribiendo: Bool

    var body: some View {
        // El encabezado y la caja van como safeAreaInset, igual que el panel anterior: en un
        // VStack normal el área de mensajes se expande sobre ellos y se queda con los clics, así
        // que los botones se ven pero no responden.
        conversacion
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top) { encabezado }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let permiso = agente.permiso {
                        tarjetaDePermiso(permiso)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if !sugerencias.isEmpty {
                        listaDeComandos
                    }
                    cajaDeTexto
                }
            }
            .safeAreaPadding(.top, 8)
            .safeAreaPadding(.bottom, 8)
            .animation(NookDesign.Motion.standard, value: agente.permiso?.id)
            .onAppear {
                agente.arrancar()
                escribiendo = true
            }
    }

    // MARK: - Encabezado

    private var encabezado: some View {
        HStack(spacing: 8) {
            Button("Cerrar", systemImage: "xmark") {
                withAnimation(NookDesign.Motion.standard) {
                    windowState.isSidebarAIChatVisible = false
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(NookIconButtonStyle())
            .foregroundStyle(Color.primary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Agente")
                    .font(NookDesign.Font.title)
                    .foregroundStyle(Color.primary.opacity(0.9))
                if let detalle = detalleDeEstado {
                    Text(detalle)
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(Color.primary.opacity(0.45))
                }
            }

            Spacer()

            Button("Limpiar", systemImage: "trash") {
                agente.limpiar()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(NookIconButtonStyle())
            .foregroundStyle(Color.primary)
            .disabled(agente.mensajes.isEmpty)
        }
        .padding(.horizontal, 8)
    }

    private var detalleDeEstado: String? {
        switch agente.estado {
        case .apagado: return nil
        case .arrancando: return "abriendo sesión…"
        case .listo: return agente.mensajes.isEmpty ? "tu suscripción, tus memorias" : nil
        case .trabajando: return agente.permiso == nil ? "trabajando…" : "esperando tu respuesta"
        case .error(let motivo): return motivo
        }
    }

    // MARK: - Conversación

    private var conversacion: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if agente.mensajes.isEmpty { bienvenida }
                    ForEach(agente.mensajes) { mensaje in
                        burbuja(mensaje).id(mensaje.id)
                    }
                    if !agente.plan.isEmpty { vistaDelPlan }
                    Color.clear.frame(height: 1).id("final")
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }
            .onChange(of: agente.mensajes.last?.texto) { _, _ in
                withAnimation(NookDesign.Motion.standard) { scroll.scrollTo("final", anchor: .bottom) }
            }
            .onChange(of: agente.mensajes.count) { _, _ in
                withAnimation(NookDesign.Motion.standard) { scroll.scrollTo("final", anchor: .bottom) }
            }
        }
    }

    private var bienvenida: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pídele algo sobre esta página, o sobre tu Mac.")
                .font(NookDesign.Font.body)
                .foregroundStyle(Color.primary.opacity(0.7))
            Text("Corre con tu propia sesión: tus memorias, tus skills y tus herramientas. Te pide permiso antes de actuar.")
                .font(NookDesign.Font.caption)
                .foregroundStyle(Color.primary.opacity(0.45))
        }
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func burbuja(_ mensaje: KurthAgentService.Mensaje) -> some View {
        switch mensaje.autor {
        case .usuario:
            HStack {
                Spacer(minLength: 32)
                Text(mensaje.texto)
                    .font(NookDesign.Font.body)
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(NookDesign.Surface.fill)
                    .clipShape(NookDesign.Radius.shape(NookDesign.Radius.md))
            }
        case .agente:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(mensaje.herramientas) { herramienta in
                    filaDeHerramienta(herramienta)
                }
                if !mensaje.texto.isEmpty {
                    Text(mensaje.texto)
                        .font(NookDesign.Font.body)
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if mensaje.enCurso && mensaje.herramientas.isEmpty {
                    puntosDeEspera
                }
            }
        }
    }

    private func filaDeHerramienta(_ herramienta: KurthAgentService.Herramienta) -> some View {
        HStack(spacing: 7) {
            Image(systemName: iconoDe(herramienta))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(herramienta.falló ? Color.red.opacity(0.8) : Color.primary.opacity(0.5))
                .frame(width: 14)
            Text(herramienta.titulo)
                .font(NookDesign.Font.caption)
                .foregroundStyle(Color.primary.opacity(herramienta.terminada ? 0.5 : 0.75))
                .lineLimit(1)
                .truncationMode(.middle)
            if !herramienta.terminada {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(NookDesign.Surface.fill.opacity(0.6))
        .clipShape(NookDesign.Radius.shape(NookDesign.Radius.sm))
    }

    private func iconoDe(_ herramienta: KurthAgentService.Herramienta) -> String {
        if herramienta.falló { return "exclamationmark.triangle" }
        switch herramienta.kind {
        case "read": return "doc.text"
        case "edit": return "pencil"
        case "execute": return "terminal"
        case "search": return "magnifyingglass"
        case "fetch": return "arrow.down.circle"
        case "think": return "bubble.left.and.bubble.right"
        default: return herramienta.terminada ? "checkmark" : "gearshape"
        }
    }

    private var puntosDeEspera: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(Color.primary.opacity(0.3))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.vertical, 4)
    }

    private var vistaDelPlan: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Plan")
                .font(NookDesign.Font.caption)
                .foregroundStyle(Color.primary.opacity(0.45))
            ForEach(Array(agente.plan.enumerated()), id: \.offset) { _, paso in
                HStack(alignment: .top, spacing: 6) {
                    Text("·").foregroundStyle(Color.primary.opacity(0.4))
                    Text(paso)
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(Color.primary.opacity(0.65))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NookDesign.Surface.fill.opacity(0.5))
        .clipShape(NookDesign.Radius.shape(NookDesign.Radius.md))
    }

    // MARK: - Permiso

    private func tarjetaDePermiso(_ permiso: KurthAgentService.Permiso) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 11, weight: .semibold))
                Text("Pide permiso")
                    .font(NookDesign.Font.caption)
                Spacer()
            }
            .foregroundStyle(Color.primary.opacity(0.6))

            Text(permiso.titulo)
                .font(NookDesign.Font.body)
                .foregroundStyle(Color.primary.opacity(0.95))
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                ForEach(permiso.opciones) { opcion in
                    Button {
                        agente.responderPermiso(opcion.id)
                    } label: {
                        Text(opcion.name)
                            .font(NookDesign.Font.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(fondoDeOpcion(opcion))
                            .clipShape(NookDesign.Radius.shape(NookDesign.Radius.sm))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.primary.opacity(0.9))
                }
            }
        }
        .padding(12)
        .background(NookDesign.Surface.fill)
        .clipShape(NookDesign.Radius.shape(NookDesign.Radius.lg))
        .overlay {
            NookDesign.Radius.shape(NookDesign.Radius.lg)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .padding(.horizontal, 8)
    }

    /// Rechazar no se pinta en rojo: el rojo empuja a leerlo como el botón peligroso, y aquí el
    /// que puede costar caro es el de permitir.
    private func fondoDeOpcion(_ opcion: KurthACPPermission.Option) -> Color {
        opcion.kind.hasPrefix("allow") ? Color.primary.opacity(0.10) : Color.primary.opacity(0.04)
    }

    // MARK: - Caja de texto

    private var cajaDeTexto: some View {
        VStack(spacing: 8) {
            TextField(marcadorDeTexto, text: $texto, axis: .vertical)
                .textFieldStyle(.plain)
                .font(NookDesign.Font.body)
                .foregroundStyle(Color.primary.opacity(0.9))
                .lineLimit(1...5)
                .focused($escribiendo)
                .disabled(!agente.estado.puedeEscribir)
                .onSubmit(enviar)
                .onKeyPress(.tab) {
                    guard let primero = sugerencias.first else { return .ignored }
                    texto = "/" + primero.name + " "
                    return .handled
                }

            HStack(spacing: 8) {
                if let modo = nombreDelModo {
                    Text(modo)
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(Color.primary.opacity(0.4))
                }
                Spacer()
                if agente.estado == .trabajando {
                    Button(action: agente.cancelar) {
                        Image(systemName: "stop.circle.fill")
                            .font(NookDesign.Font.titleLarge)
                            .foregroundStyle(Color.primary.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .help("Detener")
                } else {
                    Button(action: enviar) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(NookDesign.Font.titleLarge)
                            .foregroundStyle(Color.primary.opacity(puedeEnviar ? 0.9 : 0.3))
                    }
                    .buttonStyle(.plain)
                    .disabled(!puedeEnviar)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(NookDesign.Surface.fill)
        .clipShape(NookDesign.Radius.shape(NookDesign.Radius.lg))
        .padding(.horizontal, 8)
    }

    private var marcadorDeTexto: String {
        switch agente.estado {
        case .arrancando: return "Abriendo sesión…"
        case .error: return "El agente no arrancó"
        default: return "Pídele algo…"
        }
    }

    private var nombreDelModo: String? {
        guard let id = agente.modoActual else { return nil }
        return agente.modos.first(where: { $0.id == id })?.name
    }

    /// Lo que se ofrece al escribir «/»: los comandos del agente y las skills del usuario.
    /// Solo mientras la «/» abre el mensaje y no hay espacios: «/model» sí, «dime /algo» no.
    private var sugerencias: [KurthACPCommand] {
        guard texto.hasPrefix("/"), !texto.contains(" ") else { return [] }
        let escrito = String(texto.dropFirst())
        let encontrados = agente.comandos(queEmpiecenCon: escrito)
        // Con el nombre completo escrito ya no hay nada que sugerir.
        if encontrados.count == 1 && encontrados[0].name == escrito { return [] }
        return Array(encontrados.prefix(6))
    }

    private var listaDeComandos: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sugerencias) { comando in
                Button {
                    texto = "/" + comando.name + " "
                } label: {
                    HStack(spacing: 8) {
                        Text("/" + comando.name)
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(Color.primary.opacity(0.9))
                        if !comando.description.isEmpty {
                            Text(comando.description)
                                .font(NookDesign.Font.caption)
                                .foregroundStyle(Color.primary.opacity(0.4))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(NookDesign.Surface.fill)
        .clipShape(NookDesign.Radius.shape(NookDesign.Radius.md))
        .padding(.horizontal, 8)
    }

    private var puedeEnviar: Bool {
        agente.estado.puedeEscribir && !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func enviar() {
        guard puedeEnviar else { return }
        agente.enviar(texto)
        texto = ""
    }
}
