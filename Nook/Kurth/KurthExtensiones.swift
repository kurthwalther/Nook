// Licensed under GPL-3.0. See LICENSE.
//
//  KurthExtensiones.swift
//  Nook (rama kurth)
//
//  Tus extensiones iguales en tus Macs, por iCloud (Kurth, 26 sep: "deberían viajar por iCloud… se instala
//  sola"). Van dentro de la instantánea de KurthSync (campo `extensiones`); las reglas, en
//  KurthExtensionesModelo (con prueba sin Nook).
//
//  - Las de tienda (Chrome Web Store, Edge) la otra Mac las baja de la misma tienda; las de Safari, de la
//    app que las trae si está instalada; las de un .zip o carpeta viajan como paquete en
//    iCloud Drive/Nook/Sync/Extensiones/<id>-<versión>.zip.
//  - Se instalan solas: la hoja de permisos se salta solo si lo que pide la extensión cabe en lo que Kurth
//    aprobó en la otra Mac (ExtensionManager.performInstallation pregunta aquí, `preaprobado`). Si pide
//    más, pregunta como siempre. Solo para instalaciones que lanzó la sincronización.
//  - Lo de adentro de cada extensión (sesiones, contraseñas, filtros) no viaja: cada Mac inicia sesión una
//    vez. Así nadie con acceso a su iCloud Drive se lleva, por ejemplo, un Bitwarden abierto.
//  - Nada de extensiones se publica ni se aplica hasta que el gestor terminó de cargarlas: publicar antes
//    diría "ninguna" y la otra Mac las desinstalaría todas.
//

import AppKit
import Combine
import OSLog
import WebKit

@MainActor
final class KurthExtensiones {
    static let shared = KurthExtensiones()
    typealias Registro = KurthExtensionSincronizada

    private let log = Logger(subsystem: "com.gstudios.nook", category: "KurthExtensiones")

    /// Lo que esta Mac sabe de cada extensión (lo suyo y lo aplicado de la otra), y lo que llegó de la otra
    /// Mac y todavía no se instala aquí. Se guarda: KurthSync no vuelve a leer una instantánea ya leída, así
    /// que una instalación fallida se perdería si solo viviera en memoria.
    private struct Guardado: Codable {
        var estado: [String: Registro] = [:]
        var faltan: [String: Registro] = [:]
    }
    private var guardado = Guardado()
    /// Instalaciones en curso lanzadas por la sincronización, con lo que se aprobó en la otra Mac.
    private var preaprobadas: [String: Registro] = [:]
    /// id@versión ya intentados en esta sesión (no reintentar en cada importación).
    private var intentadas = Set<String>()
    /// Llegó algo antes de que el gestor cargara: se aplica en cuanto cargue.
    private var pendientes: [Registro] = []
    private var observadores = Set<AnyCancellable>()

    private let archivo = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.gstudios.nook/Kurth/extensiones-sync.json")

    /// iCloud Drive/Nook/Sync/Extensiones: los paquetes de las que no vienen de una tienda.
    static var carpetaDePaquetes: URL? { KurthSync.carpeta?.appendingPathComponent("Extensiones", isDirectory: true) }

    private init() {
        if let data = try? Data(contentsOf: archivo), let g = try? JSONDecoder().decode(Guardado.self, from: data) { guardado = g }
    }

    /// Lo llama KurthSync al arrancar.
    func arrancar() {
        guard observadores.isEmpty else { return }
        let m = ExtensionManager.shared
        // Instalar, desinstalar, prender o apagar cambia la lista: hay que publicar.
        m.$installedExtensions.dropFirst().receive(on: RunLoop.main).sink { _ in
            MainActor.assumeIsolated { KurthSync.shared.programarExportacion() }
        }.store(in: &observadores)
        m.$extensionsLoaded.filter { $0 }.receive(on: RunLoop.main).sink { _ in
            MainActor.assumeIsolated {
                KurthExtensiones.shared.aplicarPendientes()
                KurthSync.shared.programarExportacion()
            }
        }.store(in: &observadores)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KurthExtensiones.shared.reintentarFaltantes() }
        }
    }

    // MARK: - Publicar

    /// Para la instantánea de KurthSync. nil mientras el gestor no haya cargado (la instantánea sale sin el
    /// campo y las otras Macs no tocan nada).
    func paraSincronizar() -> [Registro]? {
        let m = ExtensionManager.shared
        guard m.isExtensionSupportAvailable, m.extensionsLoaded else { return nil }
        guardado.estado = KurthExtensionesModelo.exportar(actuales: m.installedExtensions.map(actual),
                                                          estado: guardado.estado, ahora: Date())
        guardar()
        subirPaquetes()
        return guardado.estado.values.sorted { $0.id < $1.id }
    }

    private func actual(_ e: InstalledExtension) -> KurthExtensionActual {
        let m = ExtensionManager.shared
        var permisos: [String]?, sitios: [String]?
        if let ext = m.extensionContexts[e.id]?.webExtension {
            let c = ExtensionManager.consentItems(for: ext, comparedTo: nil)
            permisos = c.permissions
            sitios = c.hosts
        }
        return KurthExtensionActual(id: e.id, nombre: e.name, version: e.version,
                                    origen: KurthExtensionesModelo.origen(id: e.id, tienda: m.fetchEntity(id: e.id)?.sourceStore),
                                    activa: e.isEnabled, permisos: permisos, sitios: sitios)
    }

    /// Las de .zip o carpeta dejan su paquete en iCloud Drive para la otra Mac (una vez por versión).
    private func subirPaquetes() {
        guard let carpeta = Self.carpetaDePaquetes else { return }
        let m = ExtensionManager.shared
        let paquetes: [(origen: URL, destino: URL, id: String)] = guardado.estado.values.compactMap { r in
            guard r.origen == .paquete, r.borrada == nil, let e = m.installedExtensions.first(where: { $0.id == r.id }),
                  e.version == r.version else { return nil }
            return (URL(fileURLWithPath: e.packagePath), carpeta.appendingPathComponent("\(r.id)-\(r.version).zip"), r.id)
        }
        guard !paquetes.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            try? fm.createDirectory(at: carpeta, withIntermediateDirectories: true)
            for p in paquetes where !fm.fileExists(atPath: p.destino.path) {
                // ditto sin --keepParent: el manifest queda en la raíz del zip, como lo espera la instalación.
                let proceso = Process()
                proceso.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                proceso.arguments = ["-c", "-k", "--norsrc", p.origen.path, p.destino.path]
                try? proceso.run()
                proceso.waitUntilExit()
                // Las versiones anteriores de la misma extensión ya no hacen falta.
                let otras = ((try? fm.contentsOfDirectory(atPath: carpeta.path)) ?? [])
                    .filter { $0.hasPrefix(p.id + "-") && $0 != p.destino.lastPathComponent }
                for o in otras { try? fm.removeItem(at: carpeta.appendingPathComponent(o)) }
            }
        }
    }

    // MARK: - Aplicar lo de la otra Mac

    /// Lo llama KurthSync con las extensiones de cada instantánea nueva de otra Mac.
    func mezclarRemotas(_ remotas: [Registro]) {
        let m = ExtensionManager.shared
        guard m.isExtensionSupportAvailable else { return }
        guard m.extensionsLoaded else { pendientes += remotas; return }
        let actuales = Dictionary(m.installedExtensions.map { ($0.id, actual($0)) }, uniquingKeysWith: { a, _ in a })
        let acciones = KurthExtensionesModelo.mezclar(remotos: remotas, estado: &guardado.estado, actuales: actuales)
        for a in acciones {
            switch a {
            case .activar(let id): m.enableExtension(id); log.info("Prendida desde la otra Mac: \(id, privacy: .public)")
            case .desactivar(let id): m.disableExtension(id); log.info("Apagada desde la otra Mac: \(id, privacy: .public)")
            case .desinstalar(let id):
                guardado.faltan[id] = nil
                m.uninstallExtension(id)
                log.info("Desinstalada desde la otra Mac: \(id, privacy: .public)")
            case .instalar(let r), .actualizar(let r):
                guardado.faltan[r.id] = r
                instalar(r)
            }
        }
        // Lo que ya no está en la otra Mac tampoco falta aquí.
        for r in remotas where r.borrada != nil { guardado.faltan[r.id] = nil }
        guardar()
    }

    private func aplicarPendientes() {
        guard !pendientes.isEmpty, ExtensionManager.shared.extensionsLoaded else { return }
        let p = pendientes
        pendientes = []
        mezclarRemotas(p)
        reintentarFaltantes()
    }

    /// Al volver a Nook: lo que llegó de la otra Mac y no se pudo instalar (sin red, paquete aún en la nube).
    func reintentarFaltantes() {
        guard ExtensionManager.shared.extensionsLoaded else { return }
        let instaladas = Set(ExtensionManager.shared.installedExtensions.map(\.id))
        for r in guardado.faltan.values where !instaladas.contains(r.id) { instalar(r) }
    }

    private func instalar(_ r: Registro, intento: Int = 1) {
        let clave = "\(r.id)@\(r.version)"
        guard intento > 1 || !intentadas.contains(clave) else { return }
        intentadas.insert(clave)
        let m = ExtensionManager.shared
        preaprobadas[r.id] = r
        let fin: (Result<InstalledExtension, ExtensionError>) -> Void = { resultado in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { KurthExtensiones.shared.termino(r, resultado) }
            }
        }
        switch r.origen {
        case .chrome, .edge:
            m.installFromWebStore(extensionId: r.id, store: r.origen == .edge ? .edge : .chrome, interactive: true, completionHandler: fin)
        case .paquete:
            guard let zip = Self.carpetaDePaquetes?.appendingPathComponent("\(r.id)-\(r.version).zip") else {
                preaprobadas[r.id] = nil
                return
            }
            if FileManager.default.fileExists(atPath: zip.path) {
                m.installExtension(from: zip, extensionId: r.id, completionHandler: fin)
            } else {
                // Todavía en la nube (o la otra Mac aún no lo sube): se pide y se vuelve a intentar.
                preaprobadas[r.id] = nil
                try? FileManager.default.startDownloadingUbiquitousItem(at: zip)
                guard intento < 10 else { log.error("El paquete de \(r.nombre, privacy: .public) no bajó de iCloud"); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    MainActor.assumeIsolated { KurthExtensiones.shared.instalar(r, intento: intento + 1) }
                }
            }
        case .safari:
            Task { @MainActor in
                guard let info = await m.discoverSafariExtensions().first(where: { $0.id == r.id }) else {
                    self.preaprobadas[r.id] = nil
                    self.log.info("\(r.nombre, privacy: .public) viene de una app que esta Mac no tiene")
                    return
                }
                m.installSafariExtension(info, completionHandler: fin)
            }
        }
    }

    private func termino(_ r: Registro, _ resultado: Result<InstalledExtension, ExtensionError>) {
        preaprobadas[r.id] = nil
        switch resultado {
        case .success:
            // Con la fecha de la otra Mac: así no rebota como un cambio hecho aquí.
            guardado.estado[r.id] = r
            guardado.faltan[r.id] = nil
            if !r.activa { ExtensionManager.shared.disableExtension(r.id) }
            log.info("Instalada desde la otra Mac: \(r.nombre, privacy: .public) \(r.version, privacy: .public)")
        case .failure(.cancelled):
            // Kurth dijo que no en la hoja de permisos (pedía más de lo aprobado allá): no insistir.
            guardado.faltan[r.id] = nil
            log.info("\(r.nombre, privacy: .public): Kurth no la aprobó en esta Mac")
        case .failure(let error):
            log.error("No pude instalar \(r.nombre, privacy: .public) desde la otra Mac: \(error.localizedDescription, privacy: .public)")
        }
        guardar()
    }

    // MARK: - Permisos ya aprobados

    /// Para ExtensionManager.performInstallation: si la instalación la lanzó la sincronización y lo que pide
    /// cabe en lo que Kurth aprobó en la otra Mac, no se vuelve a preguntar.
    static func preaprobado(_ id: String, permisos: [String], sitios: [String]) -> Bool {
        guard let r = shared.preaprobadas[id] else { return false }
        return KurthExtensionesModelo.cubre(permisos: permisos, sitios: sitios, aprobado: r)
    }

    // MARK: - Disco

    private func guardar() {
        let codificador = JSONEncoder()
        codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? codificador.encode(guardado) else { return }
        try? FileManager.default.createDirectory(at: archivo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: archivo, options: .atomic)
    }
}
