// Licensed under GPL-3.0. See LICENSE.
//
//  KurthAgentActividad.swift
//  Nook (rama kurth)
//
//  Lo que hace el agente, en una sola línea, como en Aside (Kurth, 24 sep): mientras trabaja,
//  "Corriendo un comando · 3 herramientas · 12 s" con un brillo que la recorre; al terminar,
//  "Trabajó 15 s · 3 herramientas ›", y al tocarla se abre la lista de lo que usó. Antes cada
//  herramienta era un renglón y una respuesta con cinco terminales llenaba la pantalla.
//

import SwiftUI
import NookDesign

struct KurthAgentActividad: View {
    let mensaje: KurthAgentService.Mensaje

    @State private var abierta = false
    @Environment(\.accessibilityReduceMotion) private var sinMovimiento

    private var herramientas: [KurthAgentService.Herramienta] { mensaje.herramientas }
    private var hayLista: Bool { !herramientas.isEmpty }

    var body: some View {
        // Un turno guardado antes de medir su duración y sin herramientas no tiene qué decir.
        if mensaje.enCurso || mensaje.duracion != nil || hayLista {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    guard hayLista else { return }
                    withAnimation(NookDesign.Motion.standard) { abierta.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        if mensaje.enCurso {
                            // El brillo y los segundos se recalculan con el reloj de la pantalla.
                            // Sin movimiento, solo avanza el reloj, una vez por segundo.
                            TimelineView(.animation(minimumInterval: sinMovimiento ? 1 : 1.0 / 30)) { reloj in
                                Text(lineaEnCurso(ahora: reloj.date))
                                    .modifier(KurthBrillo(fase: sinMovimiento ? nil : fase(reloj.date)))
                            }
                        } else {
                            Text(lineaTerminada)
                                .foregroundStyle(Color.primary.opacity(0.45))
                        }
                        if hayLista && !mensaje.enCurso {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(0.35))
                                .rotationEffect(.degrees(abierta ? 90 : 0))
                        }
                    }
                    .font(.system(size: KurthAgentChat.tamañoDeTexto))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(hayLista ? (abierta ? "Ocultar lo que usó" : "Ver lo que usó") : "")

                if abierta {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(herramientas) { fila($0) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - La línea

    private func lineaEnCurso(ahora: Date) -> String {
        ([actividad] + conteos + [Self.segundos(ahora.timeIntervalSince(mensaje.hora))]).joined(separator: " · ")
    }

    private var lineaTerminada: String {
        guard let duracion = mensaje.duracion else { return conteos.joined(separator: " · ") }
        return (["Trabajó " + Self.segundos(duracion)] + conteos).joined(separator: " · ")
    }

    /// Lo que está haciendo ahora: la herramienta abierta más reciente; si no hay, pensando o
    /// escribiendo la respuesta.
    private var actividad: String {
        if let abierta = herramientas.last(where: { !$0.terminada }) { return Self.queHace(abierta) }
        return mensaje.texto.isEmpty ? "Pensando" : "Escribiendo"
    }

    private var conteos: [String] {
        let skills = herramientas.filter(Self.esSkill).count
        let otras = herramientas.count - skills
        var partes: [String] = []
        if otras > 0 { partes.append(otras == 1 ? "1 herramienta" : "\(otras) herramientas") }
        if skills > 0 { partes.append(skills == 1 ? "1 skill" : "\(skills) skills") }
        return partes
    }

    private static func segundos(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
    }

    /// Una vuelta del brillo cada 1.8 s.
    private func fase(_ fecha: Date) -> Double {
        fecha.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
    }

    // MARK: - Qué hace cada herramienta, en palabras

    private static func esSkill(_ h: KurthAgentService.Herramienta) -> Bool {
        h.titulo.hasPrefix("Load skill")
    }

    /// Los títulos vienen del adaptador ("Terminal", "Read …", "Load skill: x", "mcp__nook__click"):
    /// aquí se vuelven lo que Kurth entiende que está pasando.
    static func queHace(_ h: KurthAgentService.Herramienta) -> String {
        if h.titulo.hasPrefix("Load skill: ") { return "Usando la skill " + h.titulo.dropFirst("Load skill: ".count) }
        if let nook = h.titulo.range(of: "mcp__nook__") {
            switch h.titulo[nook.upperBound...] {
            case "read_page": return "Leyendo la página"
            case "snapshot": return "Mirando la página"
            case "screenshot_tab": return "Viendo la página"
            case "click": return "Dando clic"
            case "type_text": return "Escribiendo en la página"
            case "press_key": return "Presionando una tecla"
            case "hover": return "Pasando el mouse"
            case "scroll": return "Desplazándose"
            case "select_option": return "Eligiendo una opción"
            case "handle_dialog": return "Respondiendo un diálogo"
            case "run_js": return "Corriendo código en la página"
            case "open_tab": return "Abriendo una pestaña"
            case "navigate_tab": return "Navegando"
            case "close_tab": return "Cerrando una pestaña"
            case "list_tabs": return "Revisando las pestañas"
            case "highlight", "point_to": return "Señalando"
            case "clear_highlights": return "Borrando marcas"
            default: return "Usando Nook"
            }
        }
        if h.titulo.hasPrefix("Search \"") || h.titulo == "Web search" { return "Buscando en la web" }
        switch h.kind {
        case "execute": return "Corriendo un comando"
        case "read": return "Leyendo un archivo"
        case "edit": return "Editando un archivo"
        case "search": return "Buscando en archivos"
        case "fetch": return "Consultando la web"
        case "think": return "Pensando"
        default: return "Trabajando"
        }
    }

    // MARK: - La lista, al abrirla

    private func fila(_ h: KurthAgentService.Herramienta) -> some View {
        HStack(spacing: 7) {
            Image(systemName: Self.icono(h))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(h.falló ? Color.red.opacity(0.8) : Color.primary.opacity(0.5))
                .frame(width: 14)
            // El título real (el comando, el archivo, la búsqueda), no la frase de la línea.
            Text(h.titulo)
                .font(NookDesign.Font.caption)
                .foregroundStyle(Color.primary.opacity(h.terminada ? 0.5 : 0.75))
                .lineLimit(1)
                .truncationMode(.middle)
            if !h.terminada {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(NookDesign.Surface.fill.opacity(0.6))
        .clipShape(NookDesign.Radius.shape(NookDesign.Radius.sm))
    }

    private static func icono(_ h: KurthAgentService.Herramienta) -> String {
        if h.falló { return "exclamationmark.triangle" }
        if esSkill(h) { return "sparkles" }
        switch h.kind {
        case "read": return "doc.text"
        case "edit": return "pencil"
        case "execute": return "terminal"
        case "search": return "magnifyingglass"
        case "fetch": return "arrow.down.circle"
        case "think": return "bubble.left.and.bubble.right"
        default: return h.terminada ? "checkmark" : "gearshape"
        }
    }
}

/// El brillo de "está pensando": el texto en gris y una banda más clara que lo recorre de
/// izquierda a derecha, recortada a la forma de las letras. Con `fase` nil queda quieto (reducir
/// movimiento).
struct KurthBrillo: ViewModifier {
    let fase: Double?

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.primary.opacity(0.4))
            .overlay {
                if let fase {
                    GeometryReader { geo in
                        let banda = max(48, geo.size.width * 0.4)
                        LinearGradient(colors: [.clear, Color.primary.opacity(0.9), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: banda)
                            .offset(x: -banda + fase * (geo.size.width + banda))
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
    }
}
