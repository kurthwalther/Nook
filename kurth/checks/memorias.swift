// Licensed under GPL-3.0. See LICENSE.
//
// Prueba de las Memorias de Nook (Nook/Kurth/KurthMemoriasModelo.swift) sin abrir Nook: guardar,
// fusionar duplicados, rechazar secretos (sin rechazar ids legítimos), buscar por texto y por host,
// la tienda en disco (carpeta temporal), la memoria de un workflow y la mezcla con otra Mac.
// Correr con kurth/checks/memorias.sh. Cada comprobación imprime ✅ o ❌; termina con 1 si alguna falló.
//
// No prueba lo que necesita Nook: las herramientas MCP, el contexto que se agrega al mensaje del
// panel, el popover ni la sincronización real por iCloud Drive.

import Foundation

@main
struct MemoriasCheck {
    static var fallas = 0

    static func ok(_ nombre: String, _ condicion: Bool, _ detalle: @autoclosure () -> String = "") {
        if condicion { print("✅ \(nombre)") } else { fallas += 1; print("❌ \(nombre)\n   \(detalle())") }
    }

    typealias M = KurthMemoriasModelo

    static func entrada(_ titulo: String, _ contenido: String, tipo: KurthMemoria.Tipo? = nil, hosts: [String]? = nil,
                        etiquetas: [String]? = nil, id: String? = nil, origen: KurthMemoria.Origen = .agente) -> KurthMemoriaEntrada {
        KurthMemoriaEntrada(id: id, titulo: titulo, contenido: contenido, tipo: tipo, hosts: hosts, etiquetas: etiquetas, origen: origen)
    }

    static func main() {
        var ms: [KurthMemoria] = []

        // MARK: Guardar
        let uf = try? M.guardar(entrada("Google Ads · Ultrafemme",
                                        "Cuenta 123-456-7890 bajo el MCC 702-552-7744.\nURL: https://ads.google.com/aw/overview?ocid=11122233&__c=987",
                                        tipo: .cuenta), en: &ms)
        ok("guardar crea", uf.map { if case .creada = $0 { return true }; return false } ?? false, "\(String(describing: uf))")
        let m1 = uf?.memoria
        ok("host sacado de la URL del contenido", m1?.hosts == ["ads.google.com"], "\(m1?.hosts ?? [])")
        ok("marca detectada sola", m1?.etiquetas == ["Ultrafemme"], "\(m1?.etiquetas ?? [])")
        _ = try? M.guardar(entrada("Google Ads · Krei", "Cuenta 555-111-2222.\nURL: https://ads.google.com/aw/overview?ocid=444",
                                   tipo: .cuenta), en: &ms)
        _ = try? M.guardar(entrada("Meta · Ultrafemme", "Cuenta publicitaria act_1234567890123456 en business.facebook.com",
                                   tipo: .cuenta, hosts: ["https://business.facebook.com/latest"]), en: &ms)
        _ = try? M.guardar(entrada("Reporte semanal de Krei", "Está en Looker Studio, carpeta Krei > Ventas; filtro: semana pasada",
                                   tipo: .procedimiento, hosts: ["lookerstudio.google.com"]), en: &ms)
        _ = try? M.guardar(entrada("Iriana", "Directora del grupo; lleva Krei y Luxury Avenue.", tipo: .persona,
                                   etiquetas: ["krei", "Luxury Avenue"]), en: &ms)
        ok("cinco memorias", ms.count == 5, "\(ms.count)")
        ok("etiqueta canónica (krei → Krei)", ms.last?.etiquetas == ["Krei", "Luxury Avenue"], "\(ms.last?.etiquetas ?? [])")

        // MARK: Fusionar
        let antes = ms.count
        let f = try? M.guardar(entrada("Cuenta de Google Ads de Ultrafemme", "Conversión principal: compra en la tienda en línea"), en: &ms)
        ok("parecida → se fusiona", f.map { if case .fusionada = $0 { return true }; return false } ?? false, "\(String(describing: f))")
        ok("fusionar no duplica", ms.count == antes, "\(ms.count) vs \(antes)")
        let fusionada = ms.first { $0.id == m1?.id }
        ok("fusión conserva lo viejo y suma lo nuevo",
           (fusionada?.contenido.contains("123-456-7890") ?? false) && (fusionada?.contenido.contains("Conversión principal") ?? false),
           fusionada?.contenido ?? "nil")
        let k = try? M.guardar(entrada("Google Ads · Luxury Avenue", "Cuenta 999-888-7777"), en: &ms)
        ok("otra marca en Google Ads no se fusiona", k.map { if case .creada = $0 { return true }; return false } ?? false, "\(String(describing: k))")
        let g = try? M.guardar(entrada("Google Ads", "MCC de Grupo Ultra: 702-552-7744"), en: &ms)
        ok("una general (sin la marca) no se fusiona con la de la marca",
           g.map { if case .creada = $0 { return true }; return false } ?? false, "\(String(describing: g))")
        let porId = try? M.guardar(entrada("Google Ads · Krei", "Cuenta 555-111-3333 (cambió)", id: ms[1].id), en: &ms)
        ok("con id reemplaza (así se corrige)",
           porId.map { if case .actualizada(let m) = $0 { return m.contenido == "Cuenta 555-111-3333 (cambió)" }; return false } ?? false,
           "\(String(describing: porId))")
        // Una de Kurth: la fusión del agente le suma la línea sin quitarle título ni origen.
        _ = try? M.guardar(entrada("Filtros de Kurth en GA4", "Siempre excluye tráfico interno", origen: .kurth), en: &ms)
        let deKurth = try? M.guardar(entrada("Filtros GA4 de Kurth", "Compara contra el año anterior"), en: &ms)
        ok("fusión sobre una de Kurth conserva título y origen",
           deKurth?.memoria.titulo == "Filtros de Kurth en GA4" && deKurth?.memoria.origen == .kurth
           && (deKurth?.memoria.contenido.contains("tráfico interno") ?? false)
           && (deKurth?.memoria.contenido.contains("año anterior") ?? false), "\(String(describing: deKurth))")

        // MARK: Secretos
        func rechaza(_ nombre: String, _ contenido: String) {
            var copia = ms
            do {
                _ = try M.guardar(entrada("Prueba", contenido), en: &copia)
                ok("rechaza \(nombre)", false, "se guardó: \(contenido)")
            } catch {
                ok("rechaza \(nombre)", error.localizedDescription.hasPrefix("No la guardé"), error.localizedDescription)
            }
        }
        func acepta(_ nombre: String, _ contenido: String) {
            var copia = ms
            do { _ = try M.guardar(entrada("Prueba \(nombre)", contenido), en: &copia); ok("acepta \(nombre)", true) }
            catch { ok("acepta \(nombre)", false, error.localizedDescription) }
        }
        rechaza("tarjeta Visa con espacios", "La tarjeta es 4111 1111 1111 1111")
        rechaza("tarjeta Amex pegada", "Amex 378282246310005")
        rechaza("llave de Anthropic", "sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345")
        rechaza("llave de Google", "AIzaSyA1234567890abcdefghijklmnopqrstuv")
        rechaza("token de Meta", "EAAGm0PX4ZCpsBAKZCZBZBZBxyzxyzxyzxyzxyzxyzxyzxyzxyzxyzxyzxyzAB12")
        rechaza("contraseña con etiqueta", "Usuario kurth, Contraseña: Hola123!")
        rechaza("NIP", "NIP: 4455")
        rechaza("URL con access_token", "https://graph.facebook.com/me?access_token=abcdef123456")
        rechaza("código de verificación", "código de verificación: 884201")
        rechaza("cadena al azar", "llave: nada, pero aquí va aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC2dF4gH6")
        acepta("id de Google Ads", "Cuenta 123-456-7890")
        acepta("id de Meta con prefijo (16 dígitos que pasan Luhn)", "act_4111111111111111")
        acepta("id de Meta suelto que no empieza como tarjeta", "Página 102938475610293")
        acepta("palabra clave", "Palabra clave: perfume dior")
        acepta("dónde está la llave", "La llave de SerpAPI vive en ~/.config/annie/serpapi.env")
        acepta("UUID", "Propiedad 3f2b8c1e-9a7d-4e5f-8b6a-1c2d3e4f5a6b")
        acepta("URL de Google Ads con ocid", "https://ads.google.com/aw/campaigns?ocid=11122233&authuser=0&__u=5566&__c=987")

        // MARK: Buscar
        let pedido = M.buscar(ms, texto: "ve a la cuenta de Ultrafemme de Google Ads")
        ok("texto: Ultrafemme de Google Ads primero", pedido.first?.memoria.titulo == "Google Ads · Ultrafemme",
           pedido.map { "\($0.memoria.titulo) \(String(format: "%.2f", $0.puntaje))" }.joined(separator: " | "))
        let auto = M.paraMensaje(ms, texto: "ve a la cuenta de Ultrafemme de Google Ads", host: nil)
        ok("contexto automático deja fuera Krei y Luxury Avenue",
           !auto.contains { $0.titulo.contains("Krei") || $0.titulo.contains("Luxury") }, auto.map(\.titulo).joined(separator: " | "))
        ok("contexto automático trae la cuenta", auto.first?.titulo == "Google Ads · Ultrafemme", auto.map(\.titulo).joined(separator: " | "))
        let sinAcentos = M.buscar(ms, texto: "ULTRAFÉMME meta")
        ok("sin acentos ni mayúsculas", sinAcentos.first?.memoria.titulo == "Meta · Ultrafemme",
           sinAcentos.map(\.memoria.titulo).joined(separator: " | "))
        let porNumero = M.buscar(ms, texto: "1234567890")
        ok("id con guiones se encuentra escrito junto", porNumero.first?.memoria.titulo == "Google Ads · Ultrafemme",
           porNumero.map(\.memoria.titulo).joined(separator: " | "))
        let prefijo = M.buscar(ms, texto: "reportes de ventas")
        ok("prefijo: «reportes» encuentra «Reporte»", prefijo.first?.memoria.titulo == "Reporte semanal de Krei",
           prefijo.map(\.memoria.titulo).joined(separator: " | "))
        let porHost = M.paraMensaje(ms, texto: "cambia el presupuesto de la campaña", host: "https://ads.google.com/aw/campaigns")
        ok("host: en ads.google.com trae las cuentas de Google Ads",
           !porHost.isEmpty && porHost.allSatisfy { $0.hosts.contains("ads.google.com") }, porHost.map(\.titulo).joined(separator: " | "))
        let subdominio = M.buscar(ms, texto: "", host: "www.business.facebook.com")
        ok("host con www", subdominio.first?.memoria.titulo == "Meta · Ultrafemme", subdominio.map(\.memoria.titulo).joined(separator: " | "))
        ok("nada que ver → nada", M.paraMensaje(ms, texto: "hola, ¿cómo estás?", host: "https://www.nytimes.com").isEmpty)
        let persona = M.buscar(ms, texto: "quién es Iriana")
        ok("persona", persona.first?.memoria.titulo == "Iriana", persona.map(\.memoria.titulo).joined(separator: " | "))

        // MARK: Borrar
        let idKrei = ms.first { $0.titulo == "Google Ads · Krei" }!.id
        ok("borrar", M.borrar(idKrei, en: &ms))
        ok("borrada no aparece", !M.buscar(ms, texto: "google ads krei").contains { $0.memoria.id == idKrei })
        ok("borrada queda como registro", ms.contains { $0.id == idKrei && $0.borrada != nil })
        ok("borrar dos veces → false", !M.borrar(idKrei, en: &ms))

        // MARK: Tienda
        let carpeta = FileManager.default.temporaryDirectory.appendingPathComponent("memorias-\(UUID().uuidString)")
        let tienda = KurthMemoriasTienda(archivo: carpeta.appendingPathComponent("memorias.json"))
        do {
            try tienda.guardar(ms)
            let leidas = tienda.cargar()
            // Las fechas se guardan en ISO 8601 sin fracciones de segundo: se compara lo demás.
            ok("tienda: ida y vuelta", leidas.map(\.id) == ms.map(\.id) && leidas.map(\.contenido) == ms.map(\.contenido)
               && leidas.map(\.viva) == ms.map(\.viva)
               && leidas.map(\.etiquetas) == ms.map(\.etiquetas), "\(leidas.count) vs \(ms.count)")
            var vieja = ms
            vieja[0].borrada = Date().addingTimeInterval(-40 * 24 * 3600)
            try tienda.guardar(vieja)
            ok("tienda: borradas de hace 40 días se sueltan", tienda.cargar().count == ms.count - 1)
        } catch {
            ok("tienda", false, error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: carpeta)

        // MARK: Workflow
        let wf = M.desdeWorkflow(nombre: "reporte-semanal", titulo: "Reporte semanal de Ultrafemme", descripcion: "Baja ventas",
                                 urls: ["https://ads.google.com/aw/reporting?ocid=111&__e=zzz&session=abc", "https://ads.google.com/otra",
                                        "https://lookerstudio.google.com/reporting/abc#page", "about:blank"])
        ok("workflow: una por sitio", wf?.hosts == ["ads.google.com", "lookerstudio.google.com"], "\(wf?.hosts ?? [])")
        ok("workflow: solo parámetros de cuenta", (wf?.contenido.contains("ocid=111") ?? false) && !(wf?.contenido.contains("session") ?? true)
           && !(wf?.contenido.contains("__e") ?? true), wf?.contenido ?? "nil")
        if let wf {
            var copia = ms
            let r = try? M.guardar(wf, en: &copia)
            ok("workflow: se guarda con id wf-…", r?.memoria.id == "wf-reporte-semanal" && r?.memoria.origen == .workflow
               && r?.memoria.etiquetas == ["Ultrafemme"], "\(String(describing: r))")
            let r2 = try? M.guardar(wf, en: &copia)
            ok("workflow: registrarlo otra vez actualiza, no duplica",
               r2.map { if case .actualizada = $0 { return true }; return false } ?? false && copia.filter { $0.id == "wf-reporte-semanal" }.count == 1)
            ok("workflow: no viaja a otras Macs", !M.paraSincronizar(copia).contains { $0.origen == .workflow })
        }

        // MARK: Otra Mac
        var local = ms
        var remota = ms
        let i = remota.firstIndex { $0.titulo == "Iriana" }!
        remota[i].contenido = "Directora del grupo; lleva Krei y Luxury Avenue. Esposa del CEO."
        remota[i].actualizada = Date().addingTimeInterval(60)
        remota[i].vecesUsada = 0
        local[i].vecesUsada = 7
        var nueva = KurthMemoria(id: "m-remota1", titulo: "Merchant de Krei", contenido: "Cuenta 5550001", tipo: .cuenta,
                                 hosts: ["merchants.google.com"], etiquetas: ["Krei"], origen: .agente, creada: Date())
        nueva.actualizada = Date()
        remota.append(nueva)
        let cambio = M.mezclar(M.paraSincronizar(remota), en: &local)
        ok("mezcla: hubo cambio", cambio)
        ok("mezcla: gana lo más reciente", local[i].contenido.hasSuffix("Esposa del CEO."), local[i].contenido)
        ok("mezcla: el uso local se conserva", local[i].vecesUsada == 7, "\(local[i].vecesUsada)")
        ok("mezcla: llega la nueva", local.contains { $0.id == "m-remota1" })
        var vieja = local
        vieja[i].contenido = "viejo"
        vieja[i].actualizada = Date().addingTimeInterval(-3600)
        ok("mezcla: lo viejo no pisa", !M.mezclar(vieja, en: &local) && local[i].contenido.hasSuffix("Esposa del CEO."))
        var conBorrado = local
        let j = conBorrado.firstIndex { $0.id == "m-remota1" }!
        conBorrado[j].borrada = Date().addingTimeInterval(120)
        M.mezclar(conBorrado, en: &local)
        ok("mezcla: el borrado viaja", local.first { $0.id == "m-remota1" }?.viva == false)

        // MARK: Contexto
        let bloque = M.contexto(Array(auto.prefix(2))) ?? ""
        ok("contexto: bloque con id y contenido", bloque.hasPrefix("<memorias-de-nook>") && bloque.contains("[\(m1!.id)]")
           && bloque.contains("123-456-7890"), bloque)

        print(fallas == 0 ? "\nTodo bien." : "\n\(fallas) fallas.")
        exit(fallas == 0 ? 0 : 1)
    }
}
