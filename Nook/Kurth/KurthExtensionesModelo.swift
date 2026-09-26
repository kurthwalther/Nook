// Licensed under GPL-3.0. See LICENSE.
//
//  KurthExtensionesModelo.swift
//  Nook (rama kurth)
//
//  La parte sin interfaz de KurthExtensiones: qué publica esta Mac de sus extensiones y qué hacer con lo
//  que publica la otra. Solo usa Foundation para que kurth/checks/extensiones.sh lo pruebe sin Nook.
//
//  Reglas (Kurth, 26 sep: "deberían viajar por iCloud… se instala sola"):
//  - Viaja qué extensión es, de dónde se instala, si está prendida, y lo que Kurth aprobó al instalarla
//    (permisos y sitios que pide esa versión). Lo de adentro (sesiones, contraseñas, filtros) no viaja.
//  - Gana el cambio más reciente. La fecha de un registro solo se mueve con un cambio hecho en esta Mac;
//    lo que llega de la otra se guarda con SU fecha, para que no rebote como si fuera nuevo.
//  - Una instalación que llega no cuenta como hecha hasta que termina bien: si fallara y ya estuviera
//    en el estado, la siguiente exportación la daría por desinstalada y la borraría en la otra Mac.
//

import Foundation

struct KurthExtensionSincronizada: Codable, Equatable {
    /// De dónde la saca la otra Mac: la misma tienda, la app que la trae (Safari), o el paquete que esta
    /// Mac deja en iCloud Drive (las instaladas de un .zip o una carpeta).
    enum Origen: String, Codable { case chrome, edge, safari, paquete }

    var id: String
    var nombre: String
    var version: String
    var origen: Origen
    var activa: Bool
    /// Lo que pide esa versión y Kurth aprobó al instalarla. La otra Mac se salta la hoja de permisos solo
    /// si lo que le piden cabe aquí.
    var permisos: [String]
    var sitios: [String]
    var fecha: Date
    var borrada: Date?

    var fechaDeCambio: Date { max(fecha, borrada ?? .distantPast) }

    /// Todo menos las fechas.
    func mismoContenido(_ o: KurthExtensionSincronizada) -> Bool {
        id == o.id && nombre == o.nombre && version == o.version && origen == o.origen && activa == o.activa
            && permisos == o.permisos && sitios == o.sitios && (borrada == nil) == (o.borrada == nil)
    }
}

/// Una extensión instalada en esta Mac, como la ve el gestor. `permisos`/`sitios` nil = no se pudieron leer
/// (una apagada no tiene contexto cargado): se conserva lo que ya se sabía.
struct KurthExtensionActual: Equatable {
    var id: String
    var nombre: String
    var version: String
    var origen: KurthExtensionSincronizada.Origen
    var activa: Bool
    var permisos: [String]?
    var sitios: [String]?
}

enum KurthExtensionesModelo {
    typealias Registro = KurthExtensionSincronizada

    static let vidaDeBorradas: TimeInterval = 30 * 24 * 3600

    enum Accion: Equatable {
        case instalar(Registro)
        case actualizar(Registro)
        case desinstalar(String)
        case activar(String)
        case desactivar(String)
    }

    /// El estado nuevo de esta Mac a partir de lo instalado: lo que no cambió conserva su fecha; lo nuevo o
    /// cambiado toma `ahora`; lo que se publicó antes y ya no está sale como borrado. Los borrados caducan.
    static func exportar(actuales: [KurthExtensionActual], estado: [String: Registro], ahora: Date) -> [String: Registro] {
        var nuevo = estado
        var vistas = Set<String>()
        for a in actuales {
            vistas.insert(a.id)
            let previo = estado[a.id]
            var r = Registro(id: a.id, nombre: a.nombre, version: a.version, origen: a.origen, activa: a.activa,
                             permisos: (a.permisos ?? previo?.permisos ?? []).sorted(),
                             sitios: (a.sitios ?? previo?.sitios ?? []).sorted(),
                             fecha: ahora, borrada: nil)
            if let p = previo, p.borrada == nil, p.mismoContenido(r) { r.fecha = p.fecha }
            nuevo[a.id] = r
        }
        for (id, p) in estado where !vistas.contains(id) && p.borrada == nil {
            var b = p
            b.borrada = ahora
            nuevo[id] = b
        }
        let limite = ahora.addingTimeInterval(-vidaDeBorradas)
        return nuevo.filter { ($0.value.borrada ?? .distantFuture) > limite }
    }

    /// Qué hacer con lo que publicó otra Mac. Solo cuenta un registro más reciente que lo que esta Mac ya
    /// sabe. Actualiza `estado` con lo aplicado, salvo las instalaciones: esas las anota quien las termine.
    static func mezclar(remotos: [Registro], estado: inout [String: Registro],
                        actuales: [String: KurthExtensionActual]) -> [Accion] {
        var acciones: [Accion] = []
        for r in remotos {
            if let e = estado[r.id], r.fechaDeCambio <= e.fechaDeCambio { continue }
            let local = actuales[r.id]
            if r.borrada != nil {
                if local != nil { acciones.append(.desinstalar(r.id)) }
                estado[r.id] = r
            } else if let local {
                if local.activa != r.activa { acciones.append(r.activa ? .activar(r.id) : .desactivar(r.id)) }
                // Las de tienda se actualizan solas en cada Mac; un paquete, solo si viene uno más nuevo.
                if r.origen == .paquete, esMasNueva(r.version, que: local.version) { acciones.append(.actualizar(r)) }
                estado[r.id] = r
            } else {
                acciones.append(.instalar(r))
            }
        }
        return acciones
    }

    /// Si lo que pide una instalación cabe en lo que Kurth aprobó en la otra Mac. Un patrón de todos los
    /// sitios aprobado cubre cualquier sitio.
    static func cubre(permisos: [String], sitios: [String], aprobado: Registro) -> Bool {
        guard Set(permisos).isSubset(of: aprobado.permisos) else { return false }
        let todos = ["<all_urls>", "*://*/*", "http://*/*", "https://*/*"]
        if aprobado.sitios.contains(where: { todos.contains($0) }) { return true }
        return Set(sitios).isSubset(of: aprobado.sitios)
    }

    /// "1.10.2" > "1.9"; lo que no sea número se compara como texto.
    static func esMasNueva(_ a: String, que b: String) -> Bool {
        let pa = a.split(separator: "."), pb = b.split(separator: ".")
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? String(pa[i]) : "0", y = i < pb.count ? String(pb[i]) : "0"
            if let nx = Int(x), let ny = Int(y) { if nx != ny { return nx > ny } } else if x != y { return x > y }
        }
        return false
    }

    /// De dónde sale una extensión instalada: la tienda anotada al instalarla; si no, un id con puntos es
    /// el identificador de una extensión de Safari; lo demás es un paquete (.zip o carpeta).
    static func origen(id: String, tienda: String?) -> KurthExtensionSincronizada.Origen {
        if let t = tienda, let o = KurthExtensionSincronizada.Origen(rawValue: t), o == .chrome || o == .edge { return o }
        if id.contains(".") { return .safari }
        return .paquete
    }
}
