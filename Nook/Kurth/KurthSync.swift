// Licensed under GPL-3.0. See LICENSE.
//
//  KurthSync.swift
//  Nook (rama kurth)
//
//  Tus Spaces, favoritos, fijadas, carpetas, temas y ajustes iguales en tus Macs, por iCloud Drive
//  (Kurth eligió esto sobre CloudKit el 24 sep: CloudKit obligaba a cambiar el identificador de
//  Nook y migrar sesiones, ajustes y permisos).
//
//  Cómo funciona:
//  - Cada Mac escribe SOLO su archivo, iCloud Drive/Nook/Sync/<id de la Mac>.json, con todo lo que
//    se sincroniza y la fecha de cada cosa. Nunca dos Macs escriben el mismo archivo, así que
//    iCloud no tiene conflictos que resolver. Es una instantánea chica, no la base de datos: la
//    base de datos de Nook nunca va en iCloud Drive.
//  - Cada Mac lee los archivos de las otras y, registro por registro, gana el cambio más reciente.
//    Los borrados viajan como registros con fecha de borrado (el modelo de pestañas ya los guarda
//    30 días), así que un borrado no se "revive" con la copia vieja de la otra Mac.
//  - Las pestañas abiertas no viajan: son de cada Mac, como en Arc.
//
//  La primera vez que se juntan dos Macs que ya tenían Nook: un Space con el mismo nombre es el
//  mismo Space, y una fijada o favorito con la misma dirección en el mismo lugar es el mismo; se
//  anotan como alias en vez de duplicarse. Ajustes y temas empiezan "sin fecha": cada Mac conserva
//  los suyos hasta que se cambien, y desde ahí gana el más reciente.
//
//  Los ajustes de apariencia (kurth.*) se aplican al instante; los de la ventana de Ajustes de
//  Nook quedan escritos y se ven al volver a abrir Nook (ese servicio los lee al arrancar).
//

import AppKit
import Foundation
import NookTabsCore
import NookWeb
import OSLog
import SystemConfiguration

/// Lo que una Mac deja en la carpeta de sincronización.
struct KurthInstantanea: Codable {
    var formato = 1
    var dispositivo: UUID
    var nombre: String
    var escrito: Date
    var espacios: [SpaceRecord]
    var elementos: [Item]
    /// Tema por Space (clave: id del Space); cada tema trae su fecha en `modificado`.
    var temas: [String: KurthTheme]
    var ajustes: [String: KurthAjusteSincronizado]
}

struct KurthAjusteSincronizado: Codable, Equatable {
    /// El valor tal cual lo guarda UserDefaults, como plist binario.
    var valor: Data
    var fecha: Date
}

@MainActor
final class KurthSync {
    static let shared = KurthSync()

    private let log = Logger(subsystem: "com.gstudios.nook", category: "KurthSync")

    /// Lo que esta Mac recuerda entre sesiones (no viaja).
    private struct Estado: Codable {
        var dispositivo = UUID()
        /// Lo último que se exportó del lado sincronizado: si algo sale de ahí (se desfija, se
        /// purga), se manda como borrado a las otras Macs.
        var exportados: [UUID: Item] = [:]
        /// Valor y fecha de cada ajuste, para saber cuál cambió y cuándo.
        var ajustes: [String: KurthAjusteSincronizado] = [:]
        /// id de la otra Mac → id aquí, para Spaces y elementos que resultaron ser el mismo.
        var alias: [UUID: UUID] = [:]
        /// Fecha del último archivo leído de cada Mac.
        var leidos: [UUID: Date] = [:]
    }

    private var estado = Estado()
    private weak var tabs: TabsController?
    private var arrancado = false
    private let cola = DispatchQueue(label: "com.gstudios.nook.kurthsync", qos: .utility)
    private var exportacion: DispatchWorkItem?
    private var vigilante: DispatchSourceFileSystemObject?
    private var reloj: Timer?
    /// La última instantánea escrita sin su fecha: si la nueva sale igual, no se escribe.
    private var ultimoContenido: Data?
    /// Fecha de modificación de cada archivo de las otras Macs la última vez que se leyó: solo se
    /// vuelve a leer el que cambió. Solo lo toca `cola`.
    nonisolated(unsafe) private var fechasDeArchivo: [String: Date] = [:]

    // Diagnóstico (kurth_sync_status).
    private(set) var ultimaExportacion: Date?
    private(set) var ultimaImportacion: Date?
    private(set) var otrasMacs: [String: Date] = [:]
    private(set) var ultimoError: String?

    private let archivoDeEstado: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.gstudios.nook/Kurth/sync.json")

    /// iCloud Drive/Nook/Sync. nil si iCloud Drive no está encendido en esta Mac.
    nonisolated static var carpeta: URL? {
        let raiz = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: raiz.path) else { return nil }
        return raiz.appendingPathComponent("Nook/Sync", isDirectory: true)
    }

    private init() {
        if let data = try? Data(contentsOf: archivoDeEstado), let guardado = try? JSONDecoder().decode(Estado.self, from: data) {
            estado = guardado
        }
    }

    // MARK: - Arranque

    func arrancar(tabs: TabsController) {
        guard !arrancado else { return }
        arrancado = true
        self.tabs = tabs
        guard let carpeta = Self.carpeta else {
            ultimoError = "iCloud Drive no está encendido en esta Mac"
            return
        }
        // Primera vez: los ajustes actuales quedan con fecha cero, no "ahora", para que al juntar
        // dos Macs ninguna le pise los ajustes a la otra.
        if estado.ajustes.isEmpty { anotarAjustes(fecha: Date(timeIntervalSince1970: 0)) }
        observarArbol()
        observarTemas()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KurthSync.shared.programarExportacion() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KurthSync.shared.importar() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KurthSync.shared.exportarAhora(esperar: true) }
        }
        // Respaldo del vigilante de la carpeta: un archivo sobrescrito en su lugar no la toca, y
        // no hay garantía de cómo lo actualiza iCloud. Revisar fechas cada 15 s cuesta casi nada.
        reloj = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { KurthSync.shared.importar() }
        }
        cola.async { [weak self] in
            // Crear la carpeta es el primer acceso a iCloud Drive: macOS puede pedir permiso aquí,
            // fuera del hilo principal.
            try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.vigilar(carpeta)
                    self?.importar()
                    self?.programarExportacion()
                }
            }
        }
    }

    /// Cada cambio al árbol de pestañas programa una exportación. withObservationTracking avisa
    /// una sola vez, así que se vuelve a registrar después de cada aviso.
    private func observarArbol() {
        guard let tabs else { return }
        withObservationTracking { _ = tabs.tree } onChange: {
            Task { @MainActor in
                KurthSync.shared.programarExportacion()
                KurthSync.shared.observarArbol()
            }
        }
    }

    private func observarTemas() {
        withObservationTracking { _ = KurthThemeStore.shared.saved } onChange: {
            Task { @MainActor in
                KurthSync.shared.programarExportacion()
                KurthSync.shared.observarTemas()
            }
        }
    }

    /// iCloud cambia los archivos de las otras Macs reemplazándolos en la carpeta: eso la toca.
    private func vigilar(_ carpeta: URL) {
        let fd = open(carpeta.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let fuente = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        fuente.setEventHandler { MainActor.assumeIsolated { KurthSync.shared.importar() } }
        fuente.setCancelHandler { close(fd) }
        fuente.resume()
        vigilante = fuente
    }

    // MARK: - Exportar

    func programarExportacion() {
        guard arrancado else { return }
        exportacion?.cancel()
        let trabajo = DispatchWorkItem { MainActor.assumeIsolated { KurthSync.shared.exportarAhora(esperar: false) } }
        exportacion = trabajo
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: trabajo)
    }

    private func exportarAhora(esperar: Bool) {
        guard let tabs, let carpeta = Self.carpeta else { return }
        anotarAjustes(fecha: Date())
        let arbol = tabs.tree

        // Lo sincronizado de hoy, borrados incluidos.
        var elementos: [UUID: Item] = [:]
        for item in arbol.items.values where arbol.scope(of: item.id) == .synced { elementos[item.id] = item }
        // Lo que ya no está del lado sincronizado viaja como borrado hasta que caduca.
        let limite = Date().addingTimeInterval(-TabTree.tombstoneLifetime)
        for (id, anterior) in estado.exportados where elementos[id] == nil {
            var borrado = arbol.items[id] ?? anterior
            if borrado.deletedAt == nil { borrado.deletedAt = max(borrado.modifiedAt, anterior.modifiedAt) }
            if let fecha = borrado.deletedAt, fecha > limite { elementos[id] = borrado }
        }
        estado.exportados = elementos

        let temas = Dictionary(uniqueKeysWithValues: KurthThemeStore.shared.saved.map { ($0.key.uuidString, $0.value) })
        var instantanea = KurthInstantanea(
            dispositivo: estado.dispositivo,
            nombre: Self.nombreDeLaMac,
            escrito: .distantPast,
            espacios: arbol.spaces.values.sorted { $0.id.uuidString < $1.id.uuidString },
            elementos: elementos.values.sorted { $0.id.uuidString < $1.id.uuidString },
            temas: temas,
            ajustes: estado.ajustes)
        guardarEstado()

        let codificador = JSONEncoder()
        codificador.outputFormatting = [.sortedKeys]
        guard let contenido = try? codificador.encode(instantanea), contenido != ultimoContenido else { return }
        instantanea.escrito = Date()
        guard let data = try? codificador.encode(instantanea) else { return }
        ultimoContenido = contenido
        let destino = carpeta.appendingPathComponent("\(estado.dispositivo.uuidString).json")
        let escribir = { [weak self] in
            var error: NSError?
            var fallo: Error?
            NSFileCoordinator().coordinate(writingItemAt: destino, options: .forReplacing, error: &error) { url in
                do { try data.write(to: url, options: .atomic) } catch { fallo = error }
            }
            let problema = (error ?? fallo).map { "No pude escribir en iCloud Drive: \($0.localizedDescription)" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let problema { self?.ultimoError = problema; self?.ultimoContenido = nil }
                    else { self?.ultimaExportacion = Date() }
                }
            }
        }
        if esperar { cola.sync(execute: escribir) } else { cola.async(execute: escribir) }
    }

    // MARK: - Importar

    func importar() {
        guard arrancado, let carpeta = Self.carpeta else { return }
        let propio = "\(estado.dispositivo.uuidString).json"
        cola.async { [weak self] in
            let fm = FileManager.default
            let nombres = (try? fm.contentsOfDirectory(atPath: carpeta.path)) ?? []
            var leidas: [KurthInstantanea] = []
            for nombre in nombres where nombre != propio {
                let url = carpeta.appendingPathComponent(nombre)
                // Un archivo que iCloud todavía no baja aparece como ".nombre.json.icloud".
                if nombre.hasPrefix("."), nombre.hasSuffix(".json.icloud") {
                    let real = carpeta.appendingPathComponent(String(nombre.dropFirst().dropLast(".icloud".count)))
                    try? fm.startDownloadingUbiquitousItem(at: real)
                    continue
                }
                guard nombre.hasSuffix(".json") else { continue }
                let fecha = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                if let fecha, self?.fechasDeArchivo[nombre] == fecha { continue }
                self?.fechasDeArchivo[nombre] = fecha
                var data: Data?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { data = try? Data(contentsOf: $0) }
                let decodificador = JSONDecoder()
                if let data, let i = try? decodificador.decode(KurthInstantanea.self, from: data), i.formato == 1 {
                    leidas.append(i)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.mezclar(leidas) }
            }
        }
    }

    private func mezclar(_ instantaneas: [KurthInstantanea]) {
        guard let tabs else { return }
        ultimaImportacion = Date()
        for i in instantaneas {
            otrasMacs[i.nombre] = i.escrito
            // Un archivo que no ha cambiado desde la última vez no trae nada nuevo.
            if let leido = estado.leidos[i.dispositivo], i.escrito <= leido { continue }
            mezclarArbol(i, tabs: tabs)
            mezclarTemas(i)
            mezclarAjustes(i)
            estado.leidos[i.dispositivo] = i.escrito
            log.info("Sincronizado con \(i.nombre, privacy: .public)")
        }
        guardarEstado()
    }

    /// El cambio más reciente gana; la fecha de un registro es la de su última edición o su borrado.
    private static func fecha(_ s: SpaceRecord) -> Date { max(s.modifiedAt, s.deletedAt ?? .distantPast) }
    private static func fecha(_ i: Item) -> Date { max(i.modifiedAt, i.deletedAt ?? .distantPast) }

    private static func normal(_ texto: String) -> String {
        texto.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func remapear(_ padre: Parent) -> Parent {
        let a = estado.alias
        switch padre {
        case .favorites(let s): return .favorites(spaceID: a[s] ?? s)
        case .pinned(let s): return .pinned(spaceID: a[s] ?? s)
        case .tabs(let s): return .tabs(spaceID: a[s] ?? s)
        case .folder(let f): return .folder(itemID: a[f] ?? f)
        }
    }

    private func mezclarArbol(_ i: KurthInstantanea, tabs: TabsController) {
        let local = tabs.tree
        var cambio = Change()
        var destinos = Set(estado.alias.values)

        // Spaces.
        for r in i.espacios {
            let id = estado.alias[r.id] ?? r.id
            if local.spaces[id] == nil {
                guard r.deletedAt == nil else { continue } // borrado de algo que aquí nunca existió
                if let gemelo = local.orderedSpaces.first(where: { Self.normal($0.name) == Self.normal(r.name) && !destinos.contains($0.id) }) {
                    estado.alias[r.id] = gemelo.id
                    destinos.insert(gemelo.id)
                    continue // el mismo Space: se queda como está aquí la primera vez
                }
            }
            let rec = SpaceRecord(id: id, name: r.name, icon: r.icon, accentHex: r.accentHex, order: r.order,
                                  modifiedAt: r.modifiedAt, deletedAt: r.deletedAt)
            if let actual = local.spaces[id], Self.fecha(rec) <= Self.fecha(actual) { continue }
            cambio.spaces[id] = .some(rec)
        }

        // Elementos: las carpetas antes que lo que llevan dentro, para que sus alias ya existan.
        let remotos = Dictionary(i.elementos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func profundidad(_ item: Item) -> Int {
            var n = 0, padre = item.parent, vistos: Set<UUID> = [item.id]
            while case .folder(let f) = padre, let p = remotos[f], vistos.insert(f).inserted { n += 1; padre = p.parent }
            return n
        }
        let arbolConCambios = { () -> TabTree in var t = local; t.apply(cambio); return t }
        for r in i.elementos.sorted(by: { profundidad($0) < profundidad($1) }) {
            let id = estado.alias[r.id] ?? r.id
            let rec = Item(id: id, parent: remapear(r.parent), order: r.order, kind: r.kind, customTitle: r.customTitle,
                           modifiedAt: r.modifiedAt, deletedAt: r.deletedAt)
            let actual: Item? = cambio.items[id] ?? local.items[id]
            if let actual {
                if Self.fecha(rec) > Self.fecha(actual) { cambio.items[id] = .some(rec) }
                continue
            }
            guard r.deletedAt == nil else { continue }
            // Primera vez que se ve: ¿ya hay aquí uno igual en el mismo lugar?
            if estado.alias[r.id] == nil {
                let hermanos = arbolConCambios().children(of: rec.parent)
                let gemelo = hermanos.first { h in
                    guard !destinos.contains(h.id), h.isFolder == rec.isFolder else { return false }
                    return h.isFolder ? Self.normal(h.displayTitle) == Self.normal(rec.displayTitle) : h.url == rec.url
                }
                if let gemelo {
                    estado.alias[r.id] = gemelo.id
                    destinos.insert(gemelo.id)
                    continue
                }
            }
            cambio.items[id] = .some(rec)
        }
        guard !cambio.isEmpty else { return }

        // Se aplica sobre una copia, se repara (padres que faltan, profundidad) y a Nook solo le
        // llega la diferencia, por su propio camino (TabsController.apply cierra lo que se borró,
        // mueve la selección y guarda).
        var copia = local
        copia.apply(cambio)
        copia.repair(now: Date())
        var final = Change()
        for id in Set(copia.spaces.keys).union(local.spaces.keys) where copia.spaces[id] != local.spaces[id] {
            final.spaces[id] = .some(copia.spaces[id])
        }
        for id in Set(copia.items.keys).union(local.items.keys) where copia.items[id] != local.items[id] {
            final.items[id] = .some(copia.items[id])
        }
        guard !final.isEmpty else { return }
        tabs.apply(final)
        log.info("\(final.spaces.count) Spaces y \(final.items.count) elementos desde \(i.nombre, privacy: .public)")
    }

    private func mezclarTemas(_ i: KurthInstantanea) {
        let tienda = KurthThemeStore.shared
        for (clave, tema) in i.temas {
            guard let remoto = UUID(uuidString: clave) else { continue }
            let id = estado.alias[remoto] ?? remoto
            guard tabs?.tree.space(id) != nil else { continue }
            if let actual = tienda.saved[id],
               (tema.modificado ?? .distantPast) <= (actual.modificado ?? .distantPast) { continue }
            tienda.aplicarRemoto(tema, para: id)
        }
    }

    // MARK: - Ajustes

    private static let dominio = Bundle.main.bundleIdentifier ?? "com.gstudios.nook"

    /// El nombre de la Mac ("MacBook Air de Kurth"). Host.current() hace búsquedas de red y
    /// puede tardar segundos; esto lo lee de la configuración del sistema.
    static let nombreDeLaMac: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"

    /// Los que viajan. Fuera: llaves de API, rutas de esta Mac, anchos (dependen de la pantalla),
    /// fechas internas y lo que Nook guarda para sí.
    private static let ajustesQueViajan: Set<String> = [
        "settings.searchEngine", "settings.customSearchEngines", "settings.tabUnloadTimeout",
        "settings.tabManagementMode", "settings.startupLoadMode", "settings.blockCrossSiteTracking",
        "settings.adBlockerEnabled", "settings.adBlockerWhitelist", "settings.enabledOptionalFilterLists",
        "settings.askBeforeQuit", "settings.sidebarPosition", "settings.topBarAddressView",
        "settings.showLinkStatusBar", "settings.siteSearchEntries", "settings.tabLayout",
        "settings.appearanceMode", "settings.tabOrganizerEnabled", "settings.autoRenamePinnedTabs",
        "settings.autoPictureInPicture", "settings.sponsorBlockEnabled", "settings.sponsorBlockCategoryOptions",
        "settings.siteRoutingRules", "settings.sitePermissions", "settings.mediaDownloadSites",
        "settings.youTubeHideShorts", "settings.youTubeHiddenHomeSections", "settings.youTubeVideosPerRow",
        "settings.youTubeFrameThumbnails", "settings.youTubeNoHoverPreview",
        "settings.facebookHideReels", "settings.facebookHideSuggested",
        "keyboard.shortcuts", "keyboard.shortcuts.version",
        "kurth.agentOptions", "kurth.barStyle", "kurth.blurRadius", "kurth.blurSaturation", "kurth.capsuleBlur",
        "kurth.capsuleTintOpacity", "kurth.colorExtension", "kurth.hairline", "kurth.pageRadius",
        "kurth.pageShadow", "kurth.scrollPocket", "kurth.tintOpacity", "kurth.windowMaterial",
        "kurth.windowMaterialTint", "kurth.tabLayout", "kurth.compactTabs", "kurth.barAutoHide",
        "kurth.agentCardHeight", "kurth.agentCardMaterial", "kurth.agentCardPinned",
    ]

    /// Compara cada ajuste con lo último anotado y le pone `fecha` a los que cambiaron.
    private func anotarAjustes(fecha: Date) {
        // Solo lo que el usuario guardó; los valores por defecto registrados no cuentan.
        let guardados = UserDefaults.standard.persistentDomain(forName: Self.dominio) ?? [:]
        for clave in Self.ajustesQueViajan {
            guard let valor = guardados[clave],
                  let data = try? PropertyListSerialization.data(fromPropertyList: valor, format: .binary, options: 0) else { continue }
            if let anterior = estado.ajustes[clave], Self.igual(anterior.valor, data) { continue }
            estado.ajustes[clave] = KurthAjusteSincronizado(valor: data, fecha: fecha)
        }
    }

    private func mezclarAjustes(_ i: KurthInstantanea) {
        let defaults = UserDefaults.standard
        let guardados = defaults.persistentDomain(forName: Self.dominio) ?? [:]
        for (clave, remoto) in i.ajustes where Self.ajustesQueViajan.contains(clave) {
            if let local = estado.ajustes[clave], remoto.fecha <= local.fecha { continue }
            guard let valor = try? PropertyListSerialization.propertyList(from: remoto.valor, options: [], format: nil) else { continue }
            estado.ajustes[clave] = remoto
            if let actual = guardados[clave] as AnyObject?, actual.isEqual(valor) { continue }
            defaults.set(valor, forKey: clave)
        }
    }

    /// Dos plists con el mismo contenido pueden no ser los mismos bytes (el orden de un diccionario).
    private static func igual(_ a: Data, _ b: Data) -> Bool {
        if a == b { return true }
        guard let x = try? PropertyListSerialization.propertyList(from: a, options: [], format: nil) as AnyObject,
              let y = try? PropertyListSerialization.propertyList(from: b, options: [], format: nil) else { return false }
        return x.isEqual(y)
    }

    private func guardarEstado() {
        guard let data = try? JSONEncoder().encode(estado) else { return }
        try? FileManager.default.createDirectory(at: archivoDeEstado.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: archivoDeEstado, options: .atomic)
    }

    // MARK: - MCP de desarrollo

    static let herramientas: [AIToolDefinition] = [
        AIToolDefinition(
            name: "kurth_sync_status",
            description: "Estado de la sincronización por iCloud Drive: carpeta, esta Mac, las otras Macs y cuándo escribieron, última exportación e importación, alias y errores.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]),
        AIToolDefinition(
            name: "kurth_sync_now",
            description: "Exporta e importa ya, sin esperar.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]),
    ]

    /// nil si la herramienta no es de sincronización.
    static func llamar(_ nombre: String) -> [String: Any]? {
        let s = KurthSync.shared
        switch nombre {
        case "kurth_sync_now":
            s.exportarAhora(esperar: true)
            s.importar()
            return texto("Listo: exportado y leyendo las otras Macs.")
        case "kurth_sync_status":
            let f = ISO8601DateFormatter()
            let estado: [String: Any] = [
                "carpeta": carpeta?.path ?? "iCloud Drive apagado",
                "estaMac": ["id": s.estado.dispositivo.uuidString, "nombre": nombreDeLaMac],
                "otrasMacs": s.otrasMacs.mapValues { f.string(from: $0) },
                "ultimaExportacion": s.ultimaExportacion.map { f.string(from: $0) } ?? NSNull(),
                "ultimaImportacion": s.ultimaImportacion.map { f.string(from: $0) } ?? NSNull(),
                "alias": s.estado.alias.count,
                "exportado": resumen(s.estado.exportados.values),
                "ajustesQueViajan": s.estado.ajustes.count,
                "error": s.ultimoError ?? NSNull(),
            ]
            let data = (try? JSONSerialization.data(withJSONObject: estado, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return texto(String(decoding: data, as: UTF8.self))
        default:
            return nil
        }
    }

    /// Lo exportado separado en vivo y borrado. Los borrados se guardan 30 días y son la mayoría:
    /// contarlos juntos hacía parecer que había 116 favoritos cuando había 2 (24 sep).
    private static func resumen(_ elementos: some Sequence<Item>) -> [String: Int] {
        var r = ["favoritos": 0, "fijadas": 0, "carpetas": 0, "borradosGuardados": 0]
        for e in elementos {
            if e.deletedAt != nil { r["borradosGuardados", default: 0] += 1; continue }
            if e.isFolder { r["carpetas", default: 0] += 1; continue }
            if case .favorites = e.parent { r["favoritos", default: 0] += 1 } else { r["fijadas", default: 0] += 1 }
        }
        return r
    }

    private static func texto(_ t: String) -> [String: Any] {
        ["content": [["type": "text", "text": t]]]
    }
}
