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

import AppKit
import SwiftUI
import NookDesign
import NookWeb
import NookUI

struct KurthAgentChat: View {
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(KurthAgentService.self) private var agente
    @EnvironmentObject private var browserManager: BrowserManager

    /// En el panel flotante (KurthAgentHoverOverlay): no toma el foco al asomarse, y avisa al
    /// gestor del hover cuando hay un borrador para que no se esconda a media frase.
    var flotante = false

    @State private var texto = ""
    @FocusState private var escribiendo: Bool
    /// Si este panel ya se contó como abierto en el servicio (ver onAppear / onDisappear).
    @State private var panelRegistrado = false
    /// Alto del encabezado y de la caja de abajo, para desvanecer la conversación antes de ellos.
    @State private var altoArriba: CGFloat = 0
    @State private var altoAbajo: CGFloat = 0
    /// Margen del panel abajo. La máscara de la conversación lo suma al alto de la caja: sin él,
    /// el texto se asomaba 8 pt por detrás. Arriba ya no hay margen: el encabezado mide lo mismo
    /// que la barra de la página y su fondo arranca en la orilla, como el de ella.
    private let margen: CGFloat = 8
    /// La conversación ya pasó por debajo del encabezado (enciende la línea de 1 px, como en la barra).
    @State private var desplazado = false
    @State private var confirmaBorrar = false

    // El encabezado copia la barra de la página y lee sus mismos ajustes (`kurth.*`, se cambian con
    // clic derecho en la barra): cápsulas de vidrio aquí también, o bloque difuminado aquí también.
    @AppStorage("kurth.barStyle") private var barStyle = "capsules"
    @AppStorage("kurth.blurRadius") private var blurRadius = 9.0
    @AppStorage("kurth.blurSaturation") private var blurSaturation = 1.6
    @AppStorage("kurth.tintOpacity") private var tintOpacity = 0.72
    @AppStorage("kurth.hairline") private var hairlineOpacity = 0.1
    @AppStorage("kurth.capsuleBlur") private var capsuleBlur = false
    @Environment(\.displayScale) private var displayScale
    /// La tarjeta que se asoma con hover (KurthAgentHoverOverlay) se puede fijar.
    @AppStorage(KurthAgentHoverManager.claveFijada) private var tarjetaFijada = false
    /// El material de todas las barras (KurthPanelMaterial).
    @AppStorage(KurthPanelMaterial.clave) private var material = KurthPanelMaterial.porDefecto

    private var esCapsulas: Bool { barStyle != "tinted" }
    /// Las alturas de KurthTopBarView: 44 deja 8 pt alrededor de cápsulas de 28; con tinte, 40.
    private var altoDeBarra: CGFloat { esCapsulas ? 44 : KurthChrome.topBarHeight }
    private var medidaDeIcono: CGFloat { esCapsulas ? 24 : NookDesign.Size.iconButton }
    /// Como la barra: con tinte siempre difumina lo que pasa por detrás; con cápsulas, solo si se pidió.
    private var conBlur: Bool { !esCapsulas || capsuleBlur }
    /// Cuánto se ve del texto que pasa bajo el encabezado. La barra con tinte pone el color de la
    /// página a `tintOpacity` sobre el blur; sobre el fondo liso del panel eso es lo mismo que dejar
    /// pasar el texto a 1 − tintOpacity. Con cápsulas pasa entero: sin el título "Agente" no hay
    /// nada que tapar, y los botones llevan su propio vidrio (Kurth, 25 sep).
    private var pasoBajoEncabezado: Double {
        esCapsulas ? 1 : 1 - tintOpacity
    }

    var body: some View {
        // El encabezado y la caja van como safeAreaInset, igual que el panel anterior: en un
        // VStack normal el área de mensajes se expande sobre ellos y se queda con los clics, así
        // que los botones se ven pero no responden.
        conversacion
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top) {
                encabezado
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { altoArriba = $0 }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let permiso = agente.permiso {
                        tarjetaDePermiso(permiso)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if !sugerencias.isEmpty {
                        listaDeComandos
                    }
                    // La caja con el acomodo de Aside vive en KurthAgentInput.swift.
                    KurthAgentInput(texto: $texto, escribiendo: $escribiendo, puedeEnviar: puedeEnviar,
                                    sugerencias: sugerencias, enviar: enviar)
                }
                .padding(.top, 10)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { altoAbajo = $0 }
            }
            .safeAreaPadding(.bottom, margen)
            // Borrar es empezar de cero (KurthAgentService.limpiar abre otra sesión), así que se
            // confirma. Es la hoja del sistema: el panel es angosto y una tarjeta adentro no cabe bien.
            .alert("¿Borrar la conversación?", isPresented: $confirmaBorrar) {
                Button("Borrar", role: .destructive) { borrarConversacion() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se borra lo que ves aquí y el agente empieza de cero: ya no recuerda esta plática.")
            }
            .animation(NookDesign.Motion.standard, value: agente.permiso?.id)
            // Abrir y cerrar el panel enciende y apaga el agente (KurthAgentService.panelAbierto).
            // La marca evita contar dos veces si SwiftUI repite onAppear sin onDisappear.
            .onAppear {
                if !panelRegistrado { panelRegistrado = true; agente.panelAbierto() }
                if !flotante { escribiendo = true }
            }
            .onDisappear {
                if panelRegistrado { panelRegistrado = false; agente.panelCerrado() }
                if flotante { KurthAgentHoverManager.conBorrador = false }
            }
            .onChange(of: texto) { _, nuevo in
                if flotante { KurthAgentHoverManager.conBorrador = !nuevo.isEmpty }
            }
            // Si al entrar al campo hay texto seleccionado en la página, va como chip (Señalar).
            .onChange(of: escribiendo) { _, enfocado in
                guard enfocado else { return }
                Task { await KurthSenalar.shared.adjuntarSeleccion(ventana: windowState, bm: browserManager) }
            }
    }

    // MARK: - Encabezado

    /// La misma fila que la barra de la página: a la izquierda, donde ella lleva el dominio, solo el
    /// estado cuando pide atención (ya sin el título "Agente"); a la derecha, donde ella lleva
    /// extensiones y chat, las acciones en su cápsula si la barra va en cápsulas. Sin botón de
    /// cerrar: lo cierra el mismo botón de chat de la barra que lo abrió.
    private var encabezado: some View {
        HStack(spacing: 8) {
            titulo
            Spacer(minLength: 0)
            acciones
                .modifier(KurthCapsule(active: esCapsulas))
        }
        .padding(.horizontal, esCapsulas ? 8 : NookDesign.Spacing.sm)
        .frame(height: altoDeBarra)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) { fondoDelEncabezado }
        .animation(NookDesign.Motion.standard, value: barStyle)
    }

    /// Sin "Agente" (Kurth, 25 sep: quítalo del fijo y del flotante): a la izquierda solo sale lo
    /// que pide atención, un permiso esperando o un error. Con cápsulas va en la suya, como los
    /// botones, porque la conversación ya pasa por debajo.
    private var titulo: some View {
        ZStack {
            if let detalle = detalleDeEstado {
                Text(detalle)
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 4)
                    .frame(height: KurthTopBarView.capsuleHeight)
                    .modifier(KurthCapsule(active: esCapsulas, minWidth: 1))
                    .transition(.opacity)
            }
        }
        .animation(NookDesign.Motion.quick, value: detalleDeEstado)
    }

    private var acciones: some View {
        HStack(spacing: NookDesign.Spacing.xxs) {
            if let pagina = browserManager.tabs.selectedSession(in: windowState),
               !KurthSenalar.shared.marcasGuardadas(para: pagina.url).isEmpty {
                Menu {
                    Button("Borrar las del agente") { borrarMarcas("agente") }
                    Button("Borrar las mías") { borrarMarcas("tu") }
                    Button("Borrar todas") { borrarMarcas(nil) }
                } label: {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                        .frame(width: medidaDeIcono, height: medidaDeIcono)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Marcas en esta página")
            }

            // Para comparar los dos materiales en todas las barras (Kurth, 25 sep); cuando elija
            // uno, este botón sobra.
            Button(material == "glass" ? "Pasar al material clásico" : "Pasar a vidrio",
                   systemImage: "circle.lefthalf.filled") {
                material = material == "glass" ? "panel" : "glass"
            }
            .kurthBarIcon(size: medidaDeIcono)
            .help(material == "glass" ? "Barras en vidrio · clic: clásico" : "Barras en clásico · clic: vidrio. También en Settings › Appearance")

            if flotante {
                Button(tarjetaFijada ? "Soltar" : "Fijar", systemImage: tarjetaFijada ? "pin.fill" : "pin") {
                    tarjetaFijada.toggle()
                }
                .kurthBarIcon(size: medidaDeIcono)
                .help(tarjetaFijada ? "Fijada: se queda abierta. Clic para que vuelva a esconderse" : "Fijar: que se quede abierta aunque quites el mouse")
            }

            Button("Borrar la conversación", systemImage: "trash") {
                confirmaBorrar = true
            }
            .kurthBarIcon(size: medidaDeIcono)
            .disabled(agente.mensajes.isEmpty)
            .help("Borrar la conversación")
        }
    }

    /// El fondo de la barra de la página, sin su capa de color: blur de lo que pasa por detrás y
    /// la línea de 1 px al desplazarse. La esquina de arriba que toca la ventana va concéntrica
    /// con ella; una franja cuadrada se salía del marco redondeado (Kurth, 24 sep).
    private var fondoDelEncabezado: some View {
        ZStack(alignment: .top) {
            if conBlur {
                KurthBackdropBlur(radius: blurRadius, saturation: blurSaturation, fade: 0)
                    .frame(height: altoDeBarra)
                    .clipShape(esquinasDeArriba)
                    .allowsHitTesting(false)
            }

            Rectangle()
                .fill(.primary.opacity(hairlineOpacity))
                .frame(height: 1 / displayScale)
                .frame(height: altoDeBarra, alignment: .bottom)
                .opacity(desplazado && conBlur ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.18), value: desplazado)
    }

    private var esquinasDeArriba: ConcentricRectangle {
        ConcentricRectangle(uniformTopCorners: .concentric(minimum: .fixed(0)), uniformBottomCorners: .fixed(0))
    }

    private func borrarConversacion() {
        agente.limpiar()
        KurthSenalar.shared.reiniciarNumeros()
    }

    private var detalleDeEstado: String? {
        switch agente.estado {
        case .apagado: return nil
        // Abrir la sesión se dice arriba de la caja de texto, no aquí (Kurth, 25 sep: salía dos veces).
        case .arrancando: return nil
        case .listo: return nil
        // "trabajando…" ya lo dice la línea de actividad con su brillo.
        case .trabajando: return agente.permiso == nil ? nil : "esperando tu respuesta"
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
            // Abajo, el texto se desvanece antes de llegar a la caja en vez de pasar por detrás.
            // Arriba pasa por debajo del encabezado: con cápsulas entero y desvaneciéndose solo en
            // la orilla, para que se note que sigue hacia arriba (Kurth, 25 sep); con la barra con
            // tinte, atenuado (`pasoBajoEncabezado`). La máscara usa el alto real de cada uno.
            .mask {
                VStack(spacing: 0) {
                    if esCapsulas {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 28)
                    } else {
                        Color.black.opacity(pasoBajoEncabezado).frame(height: altoArriba)
                        LinearGradient(colors: [.black.opacity(pasoBajoEncabezado), .black], startPoint: .top, endPoint: .bottom).frame(height: 16)
                    }
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
                    Color.clear.frame(height: altoAbajo + margen)
                }
                .ignoresSafeArea()
            }
            // Con el inset del encabezado, en reposo contentOffset.y es −contentInsets.top.
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 1 } action: { _, nuevo in
                desplazado = nuevo
            }
            // Al abrir el panel se ve lo último, no el principio de la conversación guardada.
            .defaultScrollAnchor(.bottom)
            .onAppear { scroll.scrollTo("final", anchor: .bottom) }
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

    /// 1 pt menos que el cuerpo de Nook (13): Kurth lo pidió en 11 y luego un punto más (24 sep).
    static let tamañoDeTexto: CGFloat = 12

    @ViewBuilder
    private func burbuja(_ mensaje: KurthAgentService.Mensaje) -> some View {
        switch mensaje.autor {
        case .usuario:
            HStack {
                Spacer(minLength: 32)
                VStack(alignment: .trailing, spacing: 4) {
                ForEach(mensaje.señalados ?? [], id: \.self) { s in
                    // Lo adjuntado llega con «📎» (KurthAgentService.enviar): se pinta con clip.
                    Label(s.hasPrefix("📎 ") ? String(s.dropFirst(2)) : s,
                          systemImage: s.hasPrefix("📎 ") ? "paperclip" : "viewfinder")
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(Color(red: 0.04, green: 0.52, blue: 1))
                        .lineLimit(1)
                }
                Text(mensaje.texto)
                    .font(.system(size: Self.tamañoDeTexto))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(NookDesign.Surface.fill)
                    .clipShape(NookDesign.Radius.shape(NookDesign.Radius.md))
                }
            }
        case .agente:
            VStack(alignment: .leading, spacing: 8) {
                // Una línea con lo que hace, las herramientas y los segundos (KurthAgentActividad).
                KurthAgentActividad(mensaje: mensaje)
                if !mensaje.texto.isEmpty {
                    KurthMarkdownText(texto: mensaje.texto, tamaño: Self.tamañoDeTexto)
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Los enlaces de la respuesta se abren en el Peek de Nook (la vista previa
                        // flotante sobre la ventana), no en una pestaña nueva ni en el navegador del
                        // sistema (Kurth, 24 sep). Desde el Peek se puede abrir como pestaña.
                        .environment(\.openURL, OpenURLAction { url in
                            if url.scheme == "kurth-marca" {
                                let id = url.absoluteString.replacingOccurrences(of: "kurth-marca:", with: "")
                                KurthSenalar.shared.irAMarca(id, ventana: windowState, bm: browserManager)
                                return .handled
                            }
                            browserManager.peekManager.presentExternalURL(
                                url, from: browserManager.tabs.selectedSession(in: windowState))
                            return .handled
                        })
                }
            }
        }
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
        .background(superficieOpaca)
        .clipShape(NookDesign.Radius.shape(NookDesign.Radius.lg))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 1)
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

    /// Fondo de la tarjeta de permiso (la caja de texto usa el mismo, en KurthAgentInput). Antes era
    /// Surface.fill (negro al 4.5 %) y los mensajes se leían a través al hacer scroll (Kurth, 24 sep).
    /// Opaco y blanco puro (oscuro en modo oscuro): sobre el panel con tema blanco, un tinte gris lo
    /// dejaba casi invisible.
    private var superficieOpaca: some View {
        Color(nsColor: .textBackgroundColor)
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

    /// La pestaña de esta ventana, como enlace para el agente (KurthACPResourceLink).
    private var paginaActiva: KurthACPResourceLink? {
        guard let pagina = browserManager.tabs.selectedSession(in: windowState) else { return nil }
        let titulo = pagina.title.isEmpty ? (pagina.url.host() ?? pagina.url.absoluteString) : pagina.title
        return KurthACPResourceLink(uri: pagina.url.absoluteString, name: titulo, title: "Pestaña que el usuario está viendo en Nook")
    }

    private var puedeEnviar: Bool {
        agente.aceptaMensajes
            && (!texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !KurthSenalar.shared.referencias.isEmpty
                || !agente.adjuntos.isEmpty)
    }

    private func borrarMarcas(_ autor: String?) {
        guard let sesion = browserManager.tabs.selectedSession(in: windowState),
              let webView = browserManager.getWebView(for: sesion.itemID, in: windowState.id) ?? sesion.webView else { return }
        KurthSenalar.shared.olvidarMarcas(url: sesion.url, autor: autor)
        Task { _ = try? await KurthCopilot.enMarcas(webView, "return window.__kurth.marcas.limpiar(autor)", ["autor": autor ?? NSNull()]) }
    }

    private func enviar() {
        guard puedeEnviar else { return }
        let escrito = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        let señalados = KurthSenalar.shared.tomarReferencias()
        let mensaje = escrito.isEmpty ? (señalados.isEmpty ? "Mira lo que te adjunté." : "Mira lo que señalé.") : escrito
        texto = ""
        let pagina = paginaActiva
        // La primera pregunta sobre una página lleva su contenido: el agente contesta sin
        // herramientas (KurthCopilot.contenidoParaAgente). Leerla toma menos de un segundo.
        guard let pagina, !agente.paginasConContenido.contains(pagina.uri),
              let sesion = browserManager.tabs.selectedSession(in: windowState),
              let webView = browserManager.getWebView(for: sesion.itemID, in: windowState.id) ?? sesion.webView else {
            agente.enviar(mensaje, pagina: pagina, señalados: señalados)
            return
        }
        Task {
            let contenido = await KurthCopilot.contenidoParaAgente(webView, url: sesion.url)
            agente.enviar(mensaje, pagina: pagina, contenido: contenido, señalados: señalados)
        }
    }
}
