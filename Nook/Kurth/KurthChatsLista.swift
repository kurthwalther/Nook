// Licensed under GPL-3.0. See LICENSE.
//
//  KurthChatsLista.swift
//  Nook (rama kurth)
//
//  Lo que se ve del multichat (KurthChats), decidido con Kurth el 28 sep:
//   · El título de la conversación va a la izquierda del encabezado del panel, donde la barra de la
//     página lleva el dominio: allá "qué estás viendo", aquí "de qué estás hablando". Tocarlo abre
//     la lista. No se agregó fila ni ancho: el panel es angosto y una tira de pestañas de chats
//     encima de la de páginas se leería como lo mismo.
//   · ✎ (a la derecha) empieza una nueva; ocupa el lugar del bote, porque borrar ya no es la acción
//     de todos los días. Borrar y renombrar van con clic derecho (o «…») sobre cada fila.
//   · Cada fila dice si esa conversación trabaja, espera un permiso o contestó sin que la vieras; el
//     título lleva un punto cuando alguna de las otras te espera.
//   · La lista también se abre con el mouse sobre la flechita (Kurth, 28 sep), y abierta así se
//     cierra sola al salir de la flechita y de la lista. Con clic se queda, como cualquier popover.
//

import AppKit
import SwiftUI
import NookDesign
import NookUI

/// El panel del agente: enseña la conversación que KurthChats tiene a la vista. Al cambiar de una a
/// otra la vista es la misma y solo cambia el agente del entorno (KurthAgentChat.cambioDeConversacion
/// pasa el borrador y el conteo de paneles). Antes se rehacía con `.id` y Nook se cerraba: destruir
/// de golpe la caja enfocada y el botón con la lista abierta dejaba ventanas del sistema colgadas de
/// la ventana, y el siguiente popover o la lista de «/» tronaban en AppKit (NSRemoteView,
/// 28 sep, tres reportes).
struct KurthAgentPanel: View {
    @Environment(KurthChats.self) private var chats
    var flotante = false

    var body: some View {
        KurthAgentChat(flotante: flotante)
            .environment(chats.activo)
    }
}

// MARK: - Título

/// El título en el encabezado del panel. Con permiso esperando o error dice eso en su lugar (lo
/// de antes, detalleDeEstado), y sigue abriendo la lista.
struct KurthChatsTitulo: View {
    @Environment(KurthChats.self) private var chats
    @Environment(KurthAgentService.self) private var agente
    /// Lo que pide atención en esta conversación ("esperando tu respuesta", un error).
    let detalle: String?
    let esCapsulas: Bool

    @State private var abierta = false
    @State private var encima = false
    /// Se abrió con el mouse sobre la flechita: se cierra sola al salir de la flechita y de la lista.
    @State private var porHover = false
    @State private var sobreFlecha = false
    @State private var sobreLista = false
    /// Hay un menú abierto (el «…» de una fila o el clic derecho): para usarlo el mouse sale de la
    /// lista, y eso no debe cerrarla.
    @State private var conMenu = false
    @State private var pendiente: Task<Void, Never>?

    /// Margen para el trayecto en diagonal de la flecha a la lista, que cruza aire.
    private static let esperaAlCerrar: Duration = .milliseconds(350)

    var body: some View {
        Button(action: clic) {
            HStack(spacing: KurthEscala.pt(4)) {
                Text(detalle ?? agente.titulo)
                    .font(KurthEscala.fuente(13))
                    .foregroundStyle(encima || abierta ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: KurthEscala.pt(9), weight: .semibold))
                    .foregroundStyle(sobreFlecha || abierta ? .secondary : .tertiary)
                    .overlay(alignment: .topTrailing) { puntoDeAviso }
                    // La zona de la flecha es más grande que el dibujo: 9 pt no se atinan con el mouse.
                    .frame(width: KurthEscala.pt(14), height: KurthTopBarView.capsuleHeight)
                    .contentShape(Rectangle())
                    .onHoverTracking(perform: flecha)
            }
            .padding(.horizontal, 4)
            .frame(height: KurthTopBarView.capsuleHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHoverTracking { encima = $0 }
        .modifier(KurthCapsule(active: esCapsulas, minWidth: 1))
        .help("Conversaciones")
        .popover(isPresented: $abierta, arrowEdge: .bottom) {
            KurthChatsLista(cerrar: { abierta = false }, fijar: { porHover = false })
                .environment(chats)
                .onHoverTracking { dentro in
                    sobreLista = dentro
                    if dentro { pendiente?.cancel() } else { programarCierre() }
                }
        }
        .onChange(of: abierta) { _, ahora in
            if !ahora { porHover = false; sobreLista = false; pendiente?.cancel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            conMenu = true
            pendiente?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            conMenu = false
            programarCierre()
        }
        .animation(NookDesign.Motion.quick, value: detalle)
    }

    private func clic() {
        pendiente?.cancel()
        // Abierta por hover, el clic la deja fija en vez de cerrarla: quien da clic ahí quería abrirla.
        if abierta, porHover { porHover = false; return }
        porHover = false
        abierta.toggle()
    }

    private func flecha(_ dentro: Bool) {
        sobreFlecha = dentro
        pendiente?.cancel()
        guard dentro else { programarCierre(); return }
        // Sin espera (Kurth, 28 sep: "se tarda, quítale esa espera"): la flecha es chica y pasar de
        // largo por ella es raro.
        guard !abierta else { return }
        porHover = true
        abierta = true
    }

    private func programarCierre() {
        guard abierta, porHover, !sobreFlecha, !sobreLista, !conMenu else { return }
        pendiente?.cancel()
        pendiente = Task { @MainActor in
            try? await Task.sleep(for: Self.esperaAlCerrar)
            guard !Task.isCancelled, porHover, !sobreFlecha, !sobreLista, !conMenu else { return }
            abierta = false
        }
    }

    /// Otra conversación pide permiso (naranja, como la mano de la tarjeta) o contestó sin que la
    /// vieras (azul).
    @ViewBuilder private var puntoDeAviso: some View {
        if let aviso = chats.aviso(fueraDe: agente) {
            Circle()
                .fill(aviso == .pidePermiso ? Color.orange : Color.accentColor)
                .frame(width: 6, height: 6)
                .offset(x: 4, y: -3)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: - Lista

struct KurthChatsLista: View {
    @Environment(KurthChats.self) private var chats
    let cerrar: () -> Void
    /// Que ya no se cierre sola al salir el mouse (se abrió con hover y ahora se está renombrando).
    var fijar: () -> Void = {}

    @State private var renombrando: UUID?
    @State private var nombre = ""
    @FocusState private var campoEnfocado: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KurthChatFila(accion: { chats.nueva(); cerrar() }) { _ in
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 14)
                    Text("Nueva conversación")
                        .font(NookDesign.Font.bodyRegular)
                    Spacer(minLength: 8)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)

            Divider().padding(.horizontal, 14).padding(.vertical, 4)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(chats.lista, id: \.id) { chat in fila(chat) }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 300)
    }

    private func fila(_ chat: KurthAgentService) -> some View {
        let esLaAbierta = chat === chats.activo
        return KurthChatFila(accion: { elegir(chat) }, seleccionada: esLaAbierta) { encima in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                KurthChatEstado(chat: chat)
                    .frame(width: 14, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    if renombrando == chat.id {
                        TextField("Nombre", text: $nombre)
                            .textFieldStyle(.plain)
                            .font(NookDesign.Font.bodyRegular.weight(.medium))
                            .focused($campoEnfocado)
                            .onSubmit { terminarRenombre(chat) }
                            .onExitCommand { renombrando = nil }
                    } else {
                        Text(chat.titulo)
                            .font(NookDesign.Font.bodyRegular.weight(esLaAbierta ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    detalle(chat)
                }
                Spacer(minLength: 6)
                ZStack(alignment: .trailing) {
                    Text(KurthChatsModelo.horaCorta(chat.ultimaActividad))
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.tertiary)
                        .opacity(encima ? 0 : 1)
                    menu(chat).opacity(encima ? 1 : 0)
                }
            }
        }
        .contextMenu { acciones(chat) }
    }

    /// La carpeta de trabajo (lo que más distingue a una de otra) y el cel si está encendido.
    private func detalle(_ chat: KurthAgentService) -> some View {
        let personal = chat.carpetaDeTrabajo.path == FileManager.default.homeDirectoryForCurrentUser.path
        return HStack(spacing: 4) {
            Image(systemName: personal ? "folder" : "folder.fill")
                .font(.system(size: 9, weight: .medium))
            Text(personal ? "Sin proyecto" : chat.carpetaDeTrabajo.lastPathComponent)
            if chat.remoto.encendido {
                Text("·")
                Image(systemName: "iphone").font(.system(size: 9, weight: .medium))
                Text("en el cel")
            }
        }
        .font(NookDesign.Font.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    @ViewBuilder private func acciones(_ chat: KurthAgentService) -> some View {
        Button("Renombrar", systemImage: "pencil") {
            nombre = chat.tituloPuesto ?? chat.titulo
            fijar()
            renombrando = chat.id
            campoEnfocado = true
        }
        .disabled(chat.mensajes.isEmpty)
        Divider()
        Button("Borrar conversación", systemImage: "trash", role: .destructive) { chats.borrar(chat) }
    }

    private func menu(_ chat: KurthAgentService) -> some View {
        Menu { acciones(chat) } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Más")
    }

    private func elegir(_ chat: KurthAgentService) {
        guard renombrando == nil else { return }
        chats.elegir(chat)
        cerrar()
    }

    private func terminarRenombre(_ chat: KurthAgentService) {
        let limpio = nombre.trimmingCharacters(in: .whitespacesAndNewlines)
        // Vacío vuelve al título que sale del primer mensaje.
        chat.tituloPuesto = limpio.isEmpty ? nil : limpio
        renombrando = nil
    }
}

/// El punto de cada fila: trabajando (azul que late), esperando un permiso (naranja) o con una
/// respuesta que no has visto (azul fijo). Sin nada que decir, vacío.
private struct KurthChatEstado: View {
    let chat: KurthAgentService

    var body: some View {
        // ZStack y no Group: vacío, un Group no ocupa nada y el título de esa fila se recorría a la
        // izquierda; el ZStack guarda la columna aunque no haya punto.
        ZStack {
            if chat.permiso != nil {
                punto(Color.orange)
                    .help("Te pide permiso")
            } else if chat.estado == .trabajando {
                punto(Color.accentColor)
                    .symbolEffect(.pulse, options: .repeating)
                    .help("Trabajando")
            } else if chat.sinLeer {
                punto(Color.accentColor)
                    .help("Contestó")
            } else if case .error = chat.estado {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("Error")
            }
        }
    }

    private func punto(_ color: Color) -> some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(color)
    }
}

/// La fila de los popovers de la capa (la misma que KurthMemoriaFila): resalte al pasar el mouse y
/// uno fijo para la que está abierta.
private struct KurthChatFila<Contenido: View>: View {
    let accion: () -> Void
    var seleccionada = false
    @ViewBuilder let contenido: (Bool) -> Contenido
    @State private var encima = false

    var body: some View {
        contenido(encima)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(seleccionada ? 0.08 : encima ? 0.05 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onTapGesture(perform: accion)
            .onHoverTracking { encima = $0 }
            .animation(NookDesign.Motion.quick, value: encima)
    }
}
