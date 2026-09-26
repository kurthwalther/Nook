// Licensed under GPL-3.0. See LICENSE.
//
// Prueba de KurthExtensionesModelo sin abrir Nook: qué publica una Mac, qué hace la otra con eso, que nada
// rebote, que un borrado no reviva y que una instalación fallida no se convierta en borrado.
// Correr con kurth/checks/extensiones.sh. Cada comprobación imprime ✅ o ❌; termina con 1 si alguna falló.

import Foundation

@main
struct ExtensionesCheck {
    static var fallas = 0
    static func ok(_ nombre: String, _ condicion: Bool, _ detalle: @autoclosure () -> String = "") {
        if condicion { print("✅ \(nombre)") } else { fallas += 1; print("❌ \(nombre)\n   \(detalle())") }
    }

    typealias M = KurthExtensionesModelo
    typealias R = KurthExtensionSincronizada

    static func actual(_ id: String, _ v: String = "1.0", activa: Bool = true, origen: R.Origen = .chrome,
                       permisos: [String]? = ["storage"], sitios: [String]? = ["<all_urls>"]) -> KurthExtensionActual {
        KurthExtensionActual(id: id, nombre: "Ext \(id)", version: v, origen: origen, activa: activa, permisos: permisos, sitios: sitios)
    }

    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_000_000), t1 = t0.addingTimeInterval(60), t2 = t0.addingTimeInterval(120)
        let ublock = "cjpalhdlnbpafiamejdnhcphjbkeiagm"

        // Mac A instala uBlock y publica.
        var estadoA = M.exportar(actuales: [actual(ublock)], estado: [:], ahora: t0)
        ok("A publica la instalada con su fecha", estadoA[ublock]?.fecha == t0 && estadoA[ublock]?.borrada == nil)
        estadoA = M.exportar(actuales: [actual(ublock)], estado: estadoA, ahora: t1)
        ok("sin cambios la fecha no se mueve", estadoA[ublock]?.fecha == t0)

        // Mac B, sin nada, la recibe: instalar. El estado no cambia hasta que la instalación termine.
        var estadoB: [String: R] = [:]
        var acciones = M.mezclar(remotos: Array(estadoA.values), estado: &estadoB, actuales: [:])
        ok("B la instala", acciones == [.instalar(estadoA[ublock]!)], "\(acciones)")
        ok("B no la anota antes de instalar", estadoB[ublock] == nil)

        // Si la instalación falla y B exporta, no sale ningún borrado.
        let fallida = M.exportar(actuales: [], estado: estadoB, ahora: t1)
        ok("una instalación fallida no se publica como borrado", fallida.isEmpty)

        // La instalación termina: B la anota con la fecha de A y al exportar no rebota como nueva.
        estadoB[ublock] = estadoA[ublock]
        estadoB = M.exportar(actuales: [actual(ublock)], estado: estadoB, ahora: t2)
        ok("lo recibido conserva la fecha de A", estadoB[ublock]?.fecha == t0)
        acciones = M.mezclar(remotos: Array(estadoB.values), estado: &estadoA, actuales: [ublock: actual(ublock)])
        ok("A no hace nada con su propio cambio de vuelta", acciones.isEmpty, "\(acciones)")

        // A la apaga; B la apaga.
        estadoA = M.exportar(actuales: [actual(ublock, activa: false, permisos: nil, sitios: nil)], estado: estadoA, ahora: t1)
        ok("apagarla es un cambio con fecha nueva", estadoA[ublock]?.fecha == t1 && estadoA[ublock]?.activa == false)
        ok("apagada conserva los permisos aprobados", estadoA[ublock]?.permisos == ["storage"])
        acciones = M.mezclar(remotos: Array(estadoA.values), estado: &estadoB, actuales: [ublock: actual(ublock)])
        ok("B la apaga", acciones == [.desactivar(ublock)], "\(acciones)")

        // A la desinstala; B la desinstala y el borrado no revive con la copia vieja de B.
        let viejaDeB = estadoB[ublock]!
        estadoA = M.exportar(actuales: [], estado: estadoA, ahora: t2)
        ok("desinstalar sale como borrado", estadoA[ublock]?.borrada == t2)
        acciones = M.mezclar(remotos: Array(estadoA.values), estado: &estadoB, actuales: [ublock: actual(ublock, activa: false)])
        ok("B la desinstala", acciones == [.desinstalar(ublock)], "\(acciones)")
        var estadoA2 = estadoA
        acciones = M.mezclar(remotos: [viejaDeB], estado: &estadoA2, actuales: [:])
        ok("una copia vieja no revive lo borrado", acciones.isEmpty, "\(acciones)")

        // Paquete: solo se actualiza con una versión más nueva.
        let pk = R(id: "abc", nombre: "Mía", version: "1.2", origen: .paquete, activa: true, permisos: [], sitios: [], fecha: t2, borrada: nil)
        var estadoC: [String: R] = [:]
        acciones = M.mezclar(remotos: [pk], estado: &estadoC, actuales: ["abc": actual("abc", "1.1", origen: .paquete)])
        ok("paquete más nuevo se actualiza", acciones == [.actualizar(pk)], "\(acciones)")

        // Preaprobación.
        let aprobado = R(id: "x", nombre: "x", version: "1", origen: .chrome, activa: true,
                         permisos: ["storage", "tabs"], sitios: ["https://mail.google.com/*"], fecha: t0, borrada: nil)
        ok("cabe en lo aprobado", M.cubre(permisos: ["tabs"], sitios: ["https://mail.google.com/*"], aprobado: aprobado))
        ok("un permiso nuevo no cabe", !M.cubre(permisos: ["tabs", "history"], sitios: [], aprobado: aprobado))
        ok("un sitio nuevo no cabe", !M.cubre(permisos: [], sitios: ["https://x.com/*"], aprobado: aprobado))
        var todo = aprobado; todo.sitios = ["<all_urls>"]
        ok("todos los sitios cubre cualquiera", M.cubre(permisos: [], sitios: ["https://x.com/*"], aprobado: todo))

        // Versiones y origen.
        ok("1.10 > 1.9", M.esMasNueva("1.10", que: "1.9"))
        ok("1.0 no > 1", !M.esMasNueva("1.0", que: "1"))
        ok("tienda chrome", M.origen(id: ublock, tienda: "chrome") == .chrome)
        ok("Safari por id con puntos", M.origen(id: "com.bitwarden.desktop.safari", tienda: nil) == .safari)
        ok("paquete sin tienda", M.origen(id: "4B9D3E0A-1C2D-4E5F-8A9B-0C1D2E3F4A5B".replacingOccurrences(of: ".", with: ""), tienda: nil) == .paquete)

        // Borrados caducan a los 30 días.
        let viejo = M.exportar(actuales: [], estado: estadoA, ahora: t2.addingTimeInterval(31 * 24 * 3600))
        ok("un borrado de hace 31 días ya no viaja", viejo[ublock] == nil)

        // Lo que viaja se lee igual del otro lado (fechas ISO en el JSON de KurthSync).
        let json = try! JSONEncoder().encode(Array(estadoA.values))
        let vuelta = try! JSONDecoder().decode([R].self, from: json)
        ok("ida y vuelta por JSON", vuelta == Array(estadoA.values))

        print(fallas == 0 ? "\nTodo bien." : "\n\(fallas) fallaron.")
        exit(fallas == 0 ? 0 : 1)
    }
}
