// Licensed under GPL-3.0. See LICENSE.
//
// Prueba de KurthChatsModelo sin abrir Nook. Correr con kurth/checks/chats.sh.
// Cada comprobación imprime ✅ o ❌; termina con 1 si alguna falló.

import Foundation

@main
struct ChatsCheck {
    static var fallas = 0

    static func igual(_ nombre: String, _ obtenido: String, _ esperado: String) {
        if obtenido == esperado { print("✅ \(nombre): \(obtenido)") } else {
            fallas += 1; print("❌ \(nombre)\n   esperado: \(esperado)\n   obtenido: \(obtenido)")
        }
    }

    static func main() {
        let t = KurthChatsModelo.titulo
        igual("sin mensaje", t(nil), "Conversación nueva")
        igual("vacío", t("  \n \n"), "Conversación nueva")
        igual("corto", t("Presupuesto Krei"), "Presupuesto Krei")
        igual("primera línea con texto", t("\n\n  Hola   bro\nsegunda"), "Hola bro")
        igual("corta en palabra", t("Revisa por qué la campaña de Longchamp no tiene impresiones desde el 11"),
              "Revisa por qué la campaña de Longchamp no…")
        igual("sin espacios", t(String(repeating: "a", count: 60)), String(repeating: "a", count: 42) + "…")
        igual("coma antes del corte", t("Uno, dos, tres, cuatro, cinco, seis, siete, ocho"), "Uno, dos, tres, cuatro, cinco, seis, siete…")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Cancun")!
        // Lunes 28 sep 2026, 15:00 en Cancún.
        let ahora = cal.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 15))!
        func h(_ segundos: TimeInterval) -> String { KurthChatsModelo.horaCorta(ahora.addingTimeInterval(-segundos), ahora: ahora, calendario: cal) }
        igual("recién", h(20), "ahora")
        igual("minutos", h(12 * 60), "12 min")
        igual("hoy", h(3 * 3600), "12:00")
        igual("ayer", h(20 * 3600), "ayer")
        igual("esta semana", h(3 * 86_400), "vie")
        igual("antes", h(16 * 86_400), "12 sep")

        print(fallas == 0 ? "\nTodo bien." : "\n\(fallas) fallas.")
        exit(fallas == 0 ? 0 : 1)
    }
}
