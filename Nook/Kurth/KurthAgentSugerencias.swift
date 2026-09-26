// Licensed under GPL-3.0. See LICENSE.
//
//  KurthAgentSugerencias.swift
//  Nook (rama kurth)
//
//  La lista que flota sobre la caja del agente al escribir «/» o «@» (plan del 26 sep, punto 4):
//
//    ┌──────────────────────────────────────────┐
//    │ Tus skills                               │
//    │ ▌/brand-hub   Abre el tablero de marca…  │   ← la elegida, con el gris de los controles
//    │  /pdf         Lee, junta o parte PDFs    │
//    │ Comandos                                 │
//    │  /compact     Resume la conversación     │
//    └──────────────────────────────────────────┘
//     (+) (⛶)
//    ┌──────────────────────────────────────────┐
//    │ /b                                  (↑)  │
//
//  Una sola superficie, la misma de la caja (blanco del texto, borde de 0.5, la misma sombra), para
//  que se lea como parte de ella y no como un menú del sistema. ↑/↓ mueven, Enter o Tab eligen, Esc
//  la cierra. Se ven 8 filas como máximo; lo demás, con scroll.
//
//  Antes (hasta el 26 sep) era un bloque dentro de la columna, arriba de la caja: empujaba la
//  conversación al aparecer, mostraba 6 sin forma de ver más, no se navegaba con teclado y mezclaba
//  las skills de Kurth con los comandos del sistema en el orden del agente.
//

import SwiftUI
import AppKit
import NookDesign

/// Una fila de la lista: un comando del agente o algo para mencionar con «@».
struct KurthSugerencia: Identifiable, Equatable {
    enum Accion: Equatable {
        case comando(String)
        case mencion(KurthMencion)
    }
    /// En este orden se agrupan; el título del grupo sale una vez, arriba de su primera fila.
    enum Grupo: String {
        case skills = "Tus skills"
        case sistema = "Comandos"
        case pestañas = "Pestañas de este Space"
        case spaces = "Spaces"
    }
    let accion: Accion
    let grupo: Grupo
    let titulo: String
    let detalle: String

    var id: String {
        switch accion {
        case .comando(let nombre): return "comando-" + nombre
        case .mencion(let mencion): return mencion.id
        }
    }
}

// MARK: - Skills del usuario contra comandos del sistema

/// El agente manda skills y comandos en una sola lista sin decir de dónde viene cada uno
/// (claude-agent-acp 0.81: `available_commands_update` trae nombre y descripción, nada más). Lo que
/// es de Kurth se reconoce en disco: una carpeta en `skills/` o un `.md` en `commands/`, en
/// `~/.claude` o en la carpeta de trabajo. Las de plugins llegan como `plugin:skill` y también son
/// suyas (él las instaló); los prompts de servidores MCP llegan como `mcp:…` y van con el sistema.
@MainActor
enum KurthSkillsLocales {
    private static var cache: (carpeta: String, hora: Date, nombres: Set<String>)?

    /// Lo que hay en disco, releído cada 10 s como mucho: la lista se evalúa en cada tecla y leer
    /// cuatro carpetas por tecla es trabajo tirado; 10 s bastan para que un skill recién guardado
    /// ("Guardar como skill…") suba al grupo de arriba sin reabrir nada.
    static func nombres(carpeta: URL) -> Set<String> {
        if let cache, cache.carpeta == carpeta.path, Date().timeIntervalSince(cache.hora) < 10 { return cache.nombres }
        let fm = FileManager.default
        var nombres = Set<String>()
        let bases = [fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
                     carpeta.appendingPathComponent(".claude")]
        for base in bases {
            let skills = (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent("skills").path)) ?? []
            nombres.formUnion(skills.filter { !$0.hasPrefix(".") })
            nombres.formUnion(comandos(en: base.appendingPathComponent("commands"), prefijo: ""))
        }
        cache = (carpeta.path, Date(), nombres)
        return nombres
    }

    /// `commands/deploy.md` es /deploy; `commands/equipo/revisar.md`, /equipo:revisar.
    private static func comandos(en carpeta: URL, prefijo: String) -> [String] {
        let fm = FileManager.default
        guard let hijos = try? fm.contentsOfDirectory(atPath: carpeta.path) else { return [] }
        return hijos.flatMap { nombre -> [String] in
            guard !nombre.hasPrefix(".") else { return [] }
            if nombre.hasSuffix(".md") { return [prefijo + String(nombre.dropLast(3))] }
            var esCarpeta: ObjCBool = false
            guard fm.fileExists(atPath: carpeta.appendingPathComponent(nombre).path, isDirectory: &esCarpeta),
                  esCarpeta.boolValue, prefijo.isEmpty else { return [] }
            return comandos(en: carpeta.appendingPathComponent(nombre), prefijo: nombre + ":")
        }
    }

    static func esDelUsuario(_ nombre: String, locales: Set<String>) -> Bool {
        if nombre.hasPrefix("mcp:") { return false }
        return locales.contains(nombre) || nombre.contains(":")
    }

    /// Lo que ofrece «/»: las skills de Kurth primero y los comandos del sistema después, cada grupo
    /// en el orden del servicio (los que empiezan con lo escrito primero, luego los más cortos).
    static func sugerencias(_ comandos: [KurthACPCommand], carpeta: URL) -> [KurthSugerencia] {
        let locales = nombres(carpeta: carpeta)
        let fila: (KurthACPCommand, KurthSugerencia.Grupo) -> KurthSugerencia = { comando, grupo in
            KurthSugerencia(accion: .comando(comando.name), grupo: grupo, titulo: "/" + comando.name,
                            detalle: comando.description)
        }
        let suyos = comandos.filter { esDelUsuario($0.name, locales: locales) }.map { fila($0, .skills) }
        let sistema = comandos.filter { !esDelUsuario($0.name, locales: locales) }.map { fila($0, .sistema) }
        return suyos + sistema
    }
}

// MARK: - La lista

struct KurthListaDeSugerencias: View {
    let sugerencias: [KurthSugerencia]
    @Binding var seleccion: Int
    let elegir: (KurthSugerencia) -> Void

    /// Dónde estaba el mouse la última vez que eligió con hover. Si la lista se desplaza con ↑/↓
    /// debajo de un mouse quieto, SwiftUI vuelve a mandar hover a la fila que quedó abajo; sin esto,
    /// el mouse le robaba la selección al teclado en cada scroll.
    @State private var ultimoPunto: CGPoint?

    static let altoDeFila: CGFloat = 28
    static let altoDeGrupo: CGFloat = 22
    static let filasVisibles = 8
    private let relleno: CGFloat = 4
    /// Mismo radio que la caja (16) y, adentro, el concéntrico para la fila elegida (16 − 4).
    private var forma: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }
    private var formaDeFila: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sugerencias.enumerated()), id: \.element.id) { indice, sugerencia in
                        if indice == 0 || sugerencias[indice - 1].grupo != sugerencia.grupo {
                            encabezado(sugerencia.grupo)
                        }
                        fila(sugerencia, elegida: indice == seleccion)
                            .id(sugerencia.id)
                            .onContinuousHover(coordinateSpace: .global) { fase in
                                guard case .active(let punto) = fase, punto != ultimoPunto else { return }
                                ultimoPunto = punto
                                seleccion = indice
                            }
                            .onTapGesture { elegir(sugerencia) }
                    }
                }
                .padding(relleno)
            }
            .scrollIndicators(.automatic)
            .frame(height: alto)
            .onChange(of: seleccion) { _, nueva in
                guard sugerencias.indices.contains(nueva) else { return }
                // Sin ancla: solo se desplaza si la fila quedó fuera, como un menú de macOS.
                scroll.scrollTo(sugerencias[nueva].id)
            }
        }
        // Material de menú de macOS sobre su propia ventana (KurthPopupFlotante): se distingue de la
        // caja blanca de abajo. La sombra la pone la ventana, que sigue esta forma.
        .background(.regularMaterial, in: forma)
        .clipShape(forma)
        .overlay { forma.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
    }

    /// Mide su contenido hasta 8 filas (más un título de grupo); de ahí en adelante, scroll.
    private var alto: CGFloat {
        let grupos = sugerencias.indices.filter { $0 == 0 || sugerencias[$0 - 1].grupo != sugerencias[$0].grupo }.count
        let contenido = CGFloat(sugerencias.count) * Self.altoDeFila + CGFloat(grupos) * Self.altoDeGrupo
        let maximo = CGFloat(Self.filasVisibles) * Self.altoDeFila + Self.altoDeGrupo
        return min(contenido, maximo) + 2 * relleno
    }

    private func encabezado(_ grupo: KurthSugerencia.Grupo) -> some View {
        Text(grupo.rawValue)
            .font(NookDesign.Font.caption)
            .foregroundStyle(Color.primary.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.bottom, 3)
            // Pegado abajo: el título pertenece a las filas que siguen, no a las de arriba.
            .frame(maxWidth: .infinity, minHeight: Self.altoDeGrupo, maxHeight: Self.altoDeGrupo, alignment: .bottomLeading)
    }

    private func fila(_ sugerencia: KurthSugerencia, elegida: Bool) -> some View {
        HStack(spacing: 8) {
            if case .mencion(let mencion) = sugerencia.accion {
                KurthIconoDeMencion(tipo: mencion.tipo)
            }
            Text(sugerencia.titulo)
                .font(.system(size: KurthAgentChat.tamañoDeTexto, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                // El nombre se lee entero antes que la descripción: la descripción cede primero.
                .layoutPriority(1)
            if !sugerencia.detalle.isEmpty {
                Text(sugerencia.detalle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.altoDeFila)
        .background {
            if elegida { formaDeFila.fill(Color.primary.opacity(0.06)) }
        }
        .contentShape(formaDeFila)
    }
}
