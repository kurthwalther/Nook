// Licensed under GPL-3.0. See LICENSE.
//
//  KurthGuardarSkill.swift
//  Nook (rama kurth)
//
//  "Guardar como skill…" (plan del 26 sep, punto 4): lo que se resolvió en la conversación del
//  panel se vuelve un skill de Claude Code, para pedirlo la próxima vez con «/nombre».
//
//  Nook no escribe en ~/.claude: le pide al agente que lo escriba él, con sus herramientas y con el
//  modo de permisos que esté puesto. Así el archivo pasa por la misma tarjeta de permiso que
//  cualquier otra escritura, y quien redacta el skill es quien sabe qué se hizo y qué falló en el
//  camino. Si Nook escribiera el archivo, tendría que resumir la conversación por su cuenta.
//
//  En el globo sale una línea corta ("Guárdalo como skill «nombre»"); las instrucciones completas
//  solo las ve el agente (KurthAgentService.enviar, parámetro paraElAgente).
//

import SwiftUI
import NookDesign

enum KurthGuardarSkill {
    /// El nombre que acepta Claude Code para un skill: minúsculas, números y guiones, hasta 64.
    /// "Reporte Semanal de Krei" → "reporte-semanal-de-krei"; los acentos se quitan, no se pierden
    /// las letras ("Médico" → "medico").
    static func nombreValido(_ crudo: String) -> String {
        let sinAcentos = crudo.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX"))
        var salida = ""
        for caracter in sinAcentos.lowercased() {
            if caracter.isASCII && (caracter.isLetter || caracter.isNumber) {
                salida.append(caracter)
            } else if !salida.isEmpty && salida.last != "-" {
                salida.append("-")
            }
        }
        while salida.hasSuffix("-") { salida.removeLast() }
        return String(salida.prefix(64))
    }

    /// Lo que se ve en el chat.
    static func textoVisible(nombre: String) -> String {
        "Guárdalo como skill «\(nombre)»"
    }

    /// Lo que recibe el agente. Pide pasos generales y no una transcripción: un skill que repite
    /// las direcciones y los ids de hoy no sirve la próxima vez.
    static func instrucciones(nombre: String) -> String {
        """
        Convierte lo que hicimos en esta conversación en un skill de Claude Code llamado «\(nombre)», \
        para que la próxima vez baste con pedir /\(nombre).

        - Escríbelo en ~/.claude/skills/\(nombre)/SKILL.md (crea la carpeta). Si ya existe, no lo \
        sobrescribas: dime qué hay y pregúntame si lo reemplazo o lo combino.
        - Arriba, frontmatter YAML con `name: \(nombre)` y `description:` en una o dos líneas: qué hace y \
        cuándo usarlo, con las frases con que yo lo pediría.
        - Abajo, los pasos para repetirlo, generalizados: nada que solo valga para hoy (direcciones de \
        una sola vez, ids, fechas), con los comandos o herramientas que funcionaron y los errores que \
        ya resolvimos para no volver a caer en ellos.
        - Si hace falta un script, ponlo en la misma carpeta y di en SKILL.md cuándo correrlo.
        - Nunca guardes contraseñas, tokens ni llaves: di dónde se leen.
        - Escríbelo con tus herramientas normales. Al terminar dime la ruta y en tres líneas qué quedó.
        """
    }
}

/// El menú «…» del encabezado del panel, con "Guardar como skill…". El nombre se pide en la hoja del
/// sistema, como la confirmación de borrar: en el panel angosto una tarjeta propia no cabe bien.
struct KurthMenuDelPanel: View {
    @Environment(KurthAgentService.self) private var agente
    let medida: CGFloat

    @State private var pidiendoNombre = false
    @State private var nombre = ""

    var body: some View {
        Menu {
            Button("Guardar como skill…", systemImage: "square.and.arrow.down") {
                nombre = ""
                pidiendoNombre = true
            }
            // Sin conversación no hay nada que guardar; con el agente ocupado, el mensaje no saldría.
            .disabled(agente.mensajes.isEmpty || !agente.aceptaMensajes)
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .frame(width: medida, height: medida)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Más")
        .alert("Guardar como skill", isPresented: $pidiendoNombre) {
            TextField("nombre-corto", text: $nombre)
            Button("Guardar") { guardar() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("El agente escribe lo que hicieron aquí en ~/.claude/skills/<nombre>/SKILL.md. Después lo pides con /nombre.")
        }
    }

    private func guardar() {
        let limpio = KurthGuardarSkill.nombreValido(nombre)
        guard !limpio.isEmpty else { return }
        agente.enviar(KurthGuardarSkill.textoVisible(nombre: limpio),
                      paraElAgente: KurthGuardarSkill.instrucciones(nombre: limpio))
    }
}
