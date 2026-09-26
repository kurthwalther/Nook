// Licensed under GPL-3.0. See LICENSE.
//
//  KurthAgentInput.swift
//  Nook (rama kurth)
//
//  La caja de texto del panel del agente, con el acomodo de Aside (Kurth, 24 y 25 sep):
//
//     (+) (⛶)                   Abriendo sesión…
//    ┌──────────────────────────────────────────┐
//    │ [adjuntos y lo señalado]                 │
//    │  Pídele algo…                       (↑)  │
//    │  🗀   🛡               ✳ Opus 5.5  medium  │
//    └──────────────────────────────────────────┘
//
//  Arriba del bloque blanco: «+» agrega archivos, imágenes o una captura de la pestaña, y Señalar
//  marca una zona de la página; a la derecha, mientras la sesión abre, "Abriendo sesión…" con el
//  brillo del agente trabajando. Se puede escribir y mandar mientras tanto: el mensaje sale en
//  cuanto la sesión quede lista (KurthAgentService.enEspera). También se pueden soltar encima
//  archivos del Finder, enlaces o imágenes. Abajo, dentro del mismo bloque (Kurth: "como antes se
//  veía bien"): carpeta y permisos a la izquierda; modelo y esfuerzo a la derecha.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WebKit
import NookDesign
import NookWeb

struct KurthAgentInput: View {
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(KurthAgentService.self) private var agente
    @EnvironmentObject private var browserManager: BrowserManager

    @Binding var texto: String
    var escribiendo: FocusState<Bool>.Binding
    let puedeEnviar: Bool
    /// Los comandos que se ofrecen al escribir «/»; Tab completa el primero.
    let sugerencias: [KurthACPCommand]
    let enviar: () -> Void

    /// Hay algo arrastrándose encima de la caja.
    @State private var soltando = false
    /// El popover del cel (QR, estado, apagar).
    @State private var popoverCel = false
    @Environment(\.accessibilityReduceMotion) private var sinMovimiento

    /// Los controles redondos miden 28 y la caja los rodea con 6. El concéntrico sería 20 (14 + 6);
    /// Kurth lo prefirió en 16 (24 sep).
    private let control: CGFloat = 28
    private let holgura: CGFloat = 6
    private var forma: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        VStack(spacing: 6) {
            filaDeArriba
            caja
        }
    }

    // MARK: - Arriba del bloque: agregar, señalar y el aviso de la sesión

    private var filaDeArriba: some View {
        let abriendo = agente.estado == .arrancando
        let remoto = KurthRemoto.shared
        return HStack(spacing: 4) {
            menuDeAgregar
            botonSeñalar
            Spacer(minLength: 8)
            if remoto.encendido {
                HStack(spacing: 5) {
                    Circle()
                        .fill(remoto.url == nil ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                    Text(remoto.url == nil ? "Conectando el cel…" : "En el cel")
                }
                .font(.system(size: KurthAgentChat.tamañoDeTexto))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .transition(.opacity)
            } else if abriendo {
                TimelineView(.animation(minimumInterval: sinMovimiento ? 1 : 1.0 / 30)) { reloj in
                    Text("Abriendo sesión…")
                        .modifier(KurthBrillo(fase: sinMovimiento ? nil : KurthBrillo.fase(reloj.date)))
                }
                .font(.system(size: KurthAgentChat.tamañoDeTexto))
                .lineLimit(1)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .animation(NookDesign.Motion.quick, value: abriendo)
        .animation(NookDesign.Motion.quick, value: remoto.encendido)
    }

    // MARK: - La caja

    private var caja: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !KurthSenalar.shared.referencias.isEmpty || !agente.adjuntos.isEmpty {
                fichas
            }
            HStack(alignment: .bottom, spacing: 6) {
                campo
                botonEnviar
            }
            filaDeOpciones
        }
        .padding(holgura)
        .background(Color(nsColor: .textBackgroundColor), in: forma)
        .overlay {
            forma.strokeBorder(soltando ? Color.accentColor : Color.primary.opacity(0.06),
                               lineWidth: soltando ? 1.5 : 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 1)
        .onDrop(of: [.fileURL, .url, .image], isTargeted: $soltando, perform: soltar)
        .animation(NookDesign.Motion.standard, value: soltando)
        .padding(.horizontal, 8)
    }

    private var campo: some View {
        TextField(marcador, text: $texto, axis: .vertical)
            .textFieldStyle(.plain)
            .font(NookDesign.Font.bodyRegular)
            .foregroundStyle(Color.primary.opacity(0.9))
            .lineLimit(1...5)
            .focused(escribiendo)
            // Sin .disabled mientras el agente trabaja: el Enter que envía desactivaba el campo a
            // media pulsación y macOS sonaba el aviso de error. Lo que se bloquea es enviar.
            .onSubmit(enviar)
            .onKeyPress(.tab) {
                guard let primero = sugerencias.first else { return .ignored }
                texto = "/" + primero.name + " "
                return .handled
            }
            .padding(.vertical, 6)
            // El texto empieza donde el icono de carpeta de abajo (6 + 8 del borde).
            .padding(.leading, 8)
            .frame(minHeight: control)
    }

    /// Siempre el mismo: que la sesión está abriendo se dice arriba del bloque, y un error, en el
    /// encabezado del panel (antes salía también aquí, dos veces; Kurth, 25 sep).
    private var marcador: String { KurthRemoto.shared.encendido ? "Sigue en el cel; apágalo para escribir aquí" : "Pídele algo…" }

    private var menuDeAgregar: some View {
        Menu {
            Button("Archivo o imagen…", systemImage: "paperclip") { elegirArchivos() }
            Button("Captura de la pestaña", systemImage: "camera.viewfinder") {
                Task { await capturarPestaña() }
            }
            .disabled(browserManager.tabs.selectedSession(in: windowState) == nil)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.7))
                .frame(width: control, height: control)
                .background(Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Agregar archivos, imágenes o una captura. También puedes soltarlos aquí.")
    }

    private var señalando: Bool { KurthSenalar.shared.modoCaja == windowState.id }

    /// Con el mismo círculo que «+»: van juntos arriba del bloque.
    private var botonSeñalar: some View {
        Button {
            KurthSenalar.shared.alternarModoCaja(en: windowState)
        } label: {
            Image(systemName: "viewfinder")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(señalando ? Color.accentColor : Color.primary.opacity(0.7))
                .frame(width: control, height: control)
                .background(señalando ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Señalar en la página (⌘⇧M): arrastra una caja sobre lo que quieras mostrarle")
    }

    @ViewBuilder
    private var botonEnviar: some View {
        let trabajando = agente.estado == .trabajando
        Button {
            if trabajando { agente.cancelar() } else { enviar() }
        } label: {
            Image(systemName: trabajando ? "stop.fill" : "arrow.up")
                .font(.system(size: trabajando ? 10 : 13, weight: .bold))
                .foregroundStyle(Color(nsColor: .textBackgroundColor))
                .frame(width: control, height: control)
                .background(Color.primary.opacity(trabajando || puedeEnviar ? 0.85 : 0.2), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!trabajando && !puedeEnviar)
        .help(trabajando ? "Detener" : "Enviar")
        .animation(NookDesign.Motion.standard, value: puedeEnviar)
    }

    // MARK: - Fichas: lo señalado y lo adjuntado

    private var fichas: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(KurthSenalar.shared.referencias) { ref in
                    fichaDeSeñalado(ref)
                }
                ForEach(agente.adjuntos) { adjunto in
                    fichaDeAdjunto(adjunto)
                }
            }
            .padding(2) // que la sombra de las fichas no se corte en el borde del scroll
        }
    }

    private func fichaDeSeñalado(_ ref: KurthSenalar.Referencia) -> some View {
        HStack(spacing: 5) {
            Text("\(ref.numero)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: 16, minHeight: 16)
                .background(Color(red: 0.04, green: 0.52, blue: 1), in: Circle())
            // Con recorte de captura, su miniatura: así se ve que va la imagen, no solo el código.
            if let datos = ref.recorte, let imagen = NSImage(data: datos) {
                Image(nsImage: imagen)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            } else {
                Image(systemName: ref.tipo == "texto" ? "text.quote" : "viewfinder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(ref.resumen)
                .font(NookDesign.Font.caption)
                .lineLimit(1)
            botonQuitar { KurthSenalar.shared.quitarReferencia(ref, bm: browserManager) }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(red: 0.04, green: 0.52, blue: 1).opacity(0.10), in: Capsule())
    }

    /// Como la tarjeta de Aside: vista previa o icono, nombre y de dónde viene.
    private func fichaDeAdjunto(_ adjunto: KurthAgentService.Adjunto) -> some View {
        HStack(spacing: 8) {
            vistaPrevia(adjunto)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(adjunto.nombre)
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(adjunto.detalle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .lineLimit(1)
            }
            .frame(maxWidth: 140, alignment: .leading)
            botonQuitar { agente.quitarAdjunto(adjunto) }
        }
        .padding(5)
        .padding(.trailing, 3)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    @ViewBuilder
    private func vistaPrevia(_ adjunto: KurthAgentService.Adjunto) -> some View {
        switch adjunto.tipo {
        case .imagen(let jpeg):
            if let imagen = NSImage(data: jpeg) {
                Image(nsImage: imagen).resizable().aspectRatio(contentMode: .fill)
            } else {
                iconoDeFicha("photo")
            }
        case .archivo(let url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
        case .enlace:
            iconoDeFicha("link")
        }
    }

    private func iconoDeFicha(_ simbolo: String) -> some View {
        Image(systemName: simbolo)
            .font(.system(size: 12))
            .foregroundStyle(Color.primary.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.05))
    }

    private func botonQuitar(_ accion: @escaping () -> Void) -> some View {
        Button(action: accion) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Quitar")
    }

    // MARK: - Abajo: carpeta, permisos, modelo

    private var filaDeOpciones: some View {
        HStack(spacing: 12) {
            menuDeCarpeta
            menuDePermisos
            botonDeCel
            Spacer(minLength: 8)
            menuDeModelo
        }
        // El icono de carpeta queda donde empieza el texto (6 + 8 = 14 del borde).
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    /// Dónde trabaja el agente: decide qué memorias tiene y qué archivos puede tocar. Solo el icono;
    /// el nombre sale al pasar el mouse y en el menú, con palomita.
    private var menuDeCarpeta: some View {
        Menu {
            ForEach(agente.carpetasRecientes, id: \.path) { carpeta in
                Button {
                    agente.cambiarCarpeta(carpeta)
                } label: {
                    if carpeta.path == agente.carpetaDeTrabajo.path {
                        Label(nombreCorto(carpeta), systemImage: "checkmark")
                    } else {
                        Text(nombreCorto(carpeta))
                    }
                }
            }
            Divider()
            Button("Elegir carpeta…") { elegirCarpeta() }
        } label: {
            etiquetaDeMenu { Image(systemName: "folder") }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Trabaja en: \(nombreCorto(agente.carpetaDeTrabajo)). Decide qué memorias tiene y qué archivos puede tocar.")
    }

    private var menuDePermisos: some View {
        let modo = opcion("mode")
        return Menu {
            if let modo {
                Picker("Permisos", selection: Binding(
                    get: { modo.currentValue },
                    set: { agente.cambiarOpcion("mode", a: $0) }
                )) {
                    ForEach(modo.choices) { eleccion in
                        Text(nombreDeEleccion("mode", eleccion)).tag(eleccion.value)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            etiquetaDeMenu {
                // Fuera de Manual se dice cuál, porque cambia qué hace sin preguntar; si el panel es
                // angosto, queda el icono (cada uno tiene el suyo).
                ViewThatFits(in: .horizontal) {
                    if let nombre = nombreDelModo(modo) {
                        HStack(spacing: 4) {
                            Image(systemName: iconoDePermisos(modo?.currentValue))
                            Text(nombre)
                        }
                    }
                    Image(systemName: iconoDePermisos(modo?.currentValue))
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(modo == nil)
        .help("Permisos: qué puede hacer el agente sin preguntarte")
    }

    /// Cel: Remote Control sobre esta conversación (KurthRemoto). Apagado, tocarlo enciende y abre el
    /// popover con el QR; encendido, abre el popover (estado, enlace, apagar). El puntito verde dice
    /// que ya hay enlace; naranja, que sigue conectando.
    private var botonDeCel: some View {
        let remoto = KurthRemoto.shared
        let ocupado = agente.estado == .trabajando || agente.permiso != nil
        return Button {
            if !remoto.encendido { agente.encenderRemoto() }
            popoverCel = true
        } label: {
            etiquetaDeMenu {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .foregroundStyle(remoto.encendido ? Color.accentColor : Color.primary.opacity(0.5))
                    .overlay(alignment: .topTrailing) {
                        if remoto.encendido {
                            Circle()
                                .fill(remoto.url == nil ? Color.orange : Color.green)
                                .frame(width: 5, height: 5)
                                .offset(x: 3, y: -2)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(ocupado && !remoto.encendido)
        .help(remoto.encendido ? "Sigue en el cel. Toca para ver el QR o apagarlo."
              : "Cel: sigue esta conversación desde la app de Claude en tu iPhone")
        .popover(isPresented: $popoverCel, arrowEdge: .top) {
            KurthRemotoPopover()
                .environment(agente)
        }
    }

    private func nombreDelModo(_ modo: KurthACPConfigOption?) -> String? {
        guard let modo, modo.currentValue != "default",
              let eleccion = modo.choices.first(where: { $0.value == modo.currentValue }) else { return nil }
        return nombreDeEleccion("mode", eleccion)
    }

    private func iconoDePermisos(_ modo: String?) -> String {
        switch modo {
        case "bypassPermissions": return "exclamationmark.shield"
        case "acceptEdits", "auto": return "checkmark.shield"
        case "plan": return "list.bullet.clipboard"
        default: return "lock.shield"
        }
    }

    /// Modelo, esfuerzo y rápido. Como el de Aside: el logo del proveedor, el modelo y el esfuerzo
    /// en gris más claro. Al angostar el panel se quita primero el esfuerzo y luego el modelo; el
    /// logo siempre queda (Kurth, 24 sep: "que se haga pequeño armoniosamente").
    private var menuDeModelo: some View {
        Menu {
            ForEach(agente.opciones.filter { $0.id != "mode" }) { opcion in
                Section(tituloDeOpcion(opcion.id)) {
                    Picker(tituloDeOpcion(opcion.id), selection: Binding(
                        get: { opcion.currentValue },
                        set: { agente.cambiarOpcion(opcion.id, a: $0) }
                    )) {
                        ForEach(opcion.choices) { eleccion in
                            Text(nombreDeEleccion(opcion.id, eleccion)).tag(eleccion.value)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        } label: {
            etiquetaDeMenu {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        logoDelProveedor
                        Text(nombreDelModelo)
                            .foregroundStyle(Color.primary.opacity(0.75))
                        if let esfuerzo = opcion("effort")?.currentValue {
                            Text(esfuerzo == "default" ? "por defecto" : esfuerzo)
                        }
                        if opcion("fast")?.currentValue == "on" {
                            Image(systemName: "bolt.fill").font(.system(size: 9))
                        }
                    }
                    HStack(spacing: 5) {
                        logoDelProveedor
                        Text(nombreDelModelo)
                            .foregroundStyle(Color.primary.opacity(0.75))
                    }
                    logoDelProveedor
                }
                .lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // Primero se mide el modelo: sin prioridad, el HStack repartía el ancho en partes iguales
        // entre permisos, el espacio y el modelo, y a 200 pt al modelo le tocaba solo el logo
        // aunque sobrara espacio (Kurth, 25 sep).
        .layoutPriority(1)
        .disabled(agente.opciones.isEmpty)
        .help("Modelo y esfuerzo del agente")
    }

    private var logoDelProveedor: some View {
        Image("kurth-claude-mark")
            .renderingMode(.template)
            .resizable()
            .frame(width: 11, height: 11)
    }

    /// Icono o texto del menú en el gris de los controles secundarios. Sin flechita hacia abajo:
    /// no sumaba (Kurth, 24 sep); que son menús se entiende al tocarlos.
    private func etiquetaDeMenu<Contenido: View>(@ViewBuilder _ contenido: () -> Contenido) -> some View {
        contenido()
            .font(NookDesign.Font.caption)
            .foregroundStyle(Color.primary.opacity(0.5))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }

    private func opcion(_ id: String) -> KurthACPConfigOption? {
        agente.opciones.first { $0.id == id }
    }

    private var nombreDelModelo: String {
        guard let modelo = opcion("model"),
              let eleccion = modelo.choices.first(where: { $0.value == modelo.currentValue }) else { return "Modelo" }
        return nombreDeEleccion("model", eleccion)
    }

    private func tituloDeOpcion(_ id: String) -> String {
        switch id {
        case "model": return "Modelo"
        case "effort": return "Esfuerzo"
        case "mode": return "Permisos"
        case "fast": return "Modo rápido"
        default: return id
        }
    }

    /// Los modelos con el nombre del agente ("Opus 5.5"); el esfuerzo con la palabra del CLI
    /// ("xhigh"); los modos y "rápido" en español.
    private func nombreDeEleccion(_ id: String, _ eleccion: KurthACPConfigOption.Choice) -> String {
        switch (id, eleccion.value) {
        case ("effort", "default"), ("model", "default"): return "Por defecto" // no "Default (recommended)"
        case ("effort", _): return eleccion.value
        case ("mode", "default"): return "Manual"
        case ("mode", "acceptEdits"): return "Aceptar ediciones"
        case ("mode", "plan"): return "Plan"
        case ("mode", "auto"): return "Auto"
        case ("mode", "bypassPermissions"): return "Sin permisos"
        case ("fast", "on"): return "Encendido"
        case ("fast", "off"): return "Apagado"
        default: return eleccion.name
        }
    }

    private func nombreCorto(_ url: URL) -> String {
        url.path == FileManager.default.homeDirectoryForCurrentUser.path ? "Carpeta personal" : url.lastPathComponent
    }

    private func elegirCarpeta() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = agente.carpetaDeTrabajo
        panel.prompt = "Trabajar aquí"
        panel.message = "El agente leerá las memorias de esta carpeta y podrá actuar sobre sus archivos."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        agente.cambiarCarpeta(url)
    }

    // MARK: - Agregar: «+», soltar y captura

    private func elegirArchivos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Adjuntar"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { Self.adjuntarArchivo(url, a: agente) }
    }

    /// Del Finder llegan URLs de archivo; de una página o de la barra, enlaces; de otras apps,
    /// imágenes sueltas. Cada proveedor se lee aparte y se agrega cuando termina de cargar.
    private func soltar(_ proveedores: [NSItemProvider]) -> Bool {
        let agente = self.agente
        var aceptado = false
        for proveedor in proveedores {
            if proveedor.canLoadObject(ofClass: URL.self) {
                aceptado = true
                _ = proveedor.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if url.isFileURL { Self.adjuntarArchivo(url, a: agente) } else { Self.adjuntarEnlace(url, a: agente) }
                    }
                }
            } else if proveedor.canLoadObject(ofClass: NSImage.self) {
                aceptado = true
                _ = proveedor.loadObject(ofClass: NSImage.self) { objeto, _ in
                    guard let imagen = objeto as? NSImage, let jpeg = Self.jpeg(imagen) else { return }
                    Task { @MainActor in
                        agente.adjuntar(.init(tipo: .imagen(jpeg), nombre: "Imagen", detalle: "Arrastrada"))
                    }
                }
            }
        }
        return aceptado
    }

    /// Las imágenes van dentro del mensaje (el modelo las ve sin leer el disco); lo demás, como
    /// enlace al archivo para que el agente lo abra con sus herramientas.
    @MainActor private static func adjuntarArchivo(_ url: URL, a agente: KurthAgentService) {
        let carpeta = url.deletingLastPathComponent().lastPathComponent
        if let tipo = UTType(filenameExtension: url.pathExtension), tipo.conforms(to: .image),
           let imagen = NSImage(contentsOf: url), let jpeg = Self.jpeg(imagen) {
            agente.adjuntar(.init(tipo: .imagen(jpeg), nombre: url.lastPathComponent, detalle: carpeta))
        } else {
            agente.adjuntar(.init(tipo: .archivo(url), nombre: url.lastPathComponent, detalle: carpeta))
        }
    }

    @MainActor private static func adjuntarEnlace(_ url: URL, a agente: KurthAgentService) {
        let dominio = url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        let nombre = url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? dominio : url.lastPathComponent
        agente.adjuntar(.init(tipo: .enlace(url), nombre: nombre, detalle: dominio))
    }

    /// Lo que se ve de la pestaña, como imagen: para preguntar por diseño, gráficas o fotos.
    private func capturarPestaña() async {
        guard let sesion = browserManager.tabs.selectedSession(in: windowState),
              let webView = browserManager.getWebView(for: sesion.itemID, in: windowState.id) ?? sesion.webView else { return }
        let config = WKSnapshotConfiguration()
        let escala = webView.window?.backingScaleFactor ?? 2
        config.snapshotWidth = NSNumber(value: min(webView.bounds.width, 1600 / escala))
        guard let imagen = try? await webView.takeSnapshot(configuration: config), let jpeg = Self.jpeg(imagen) else { return }
        let dominio = sesion.url.host()?.replacingOccurrences(of: "www.", with: "") ?? "Pestaña"
        agente.adjuntar(.init(tipo: .imagen(jpeg), nombre: "Captura", detalle: dominio))
    }

    /// JPEG sobre blanco (sin transparencia, que en JPEG sale negra), con el lado largo en 1600 px
    /// como máximo: más grande solo pesa en el mensaje, el modelo no ve más.
    nonisolated static func jpeg(_ imagen: NSImage, ladoMaximo: CGFloat = 1600) -> Data? {
        guard let cg = imagen.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let escala = min(1, ladoMaximo / CGFloat(max(cg.width, cg.height)))
        let ancho = max(1, Int(CGFloat(cg.width) * escala)), alto = max(1, Int(CGFloat(cg.height) * escala))
        guard let contexto = CGContext(data: nil, width: ancho, height: alto, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        contexto.setFillColor(CGColor(gray: 1, alpha: 1))
        contexto.fill(CGRect(x: 0, y: 0, width: ancho, height: alto))
        contexto.interpolationQuality = .high
        contexto.draw(cg, in: CGRect(x: 0, y: 0, width: ancho, height: alto))
        guard let final = contexto.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: final).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
