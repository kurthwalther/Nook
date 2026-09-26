// Licensed under GPL-3.0. See LICENSE.
//
//  KurthWorkflowsProgramador.swift
//  Nook (rama kurth)
//
//  Workflows programados (Kurth, 26 sep: "que se puedan programar"). La regla vive en el JSON de
//  cada workflow (KurthWorkflowProgramacion) y aquí hay un solo temporizador: una Task dormida hasta
//  la corrida más próxima de todas. No hay sondeo; se rearma al guardar, al despertar la Mac, al
//  cambiar la hora del sistema y al abrir Nook.
//
//  Lo que no hace, a propósito:
//   · No despierta la Mac (pmset pide root) ni corre nada con Nook cerrado.
//   · No corre a ciegas lo que se pasó. Task.sleep usa el reloj continuo, que sigue contando con la
//     Mac dormida: al despertar, la Task vence de inmediato y aquí se ve que ya es tarde (más de 2
//     minutos): la corrida queda como "saltada", el popover ofrece "Correr ahora" y sale una
//     notificación. Igual al abrir Nook con una hora ya pasada.
//
//  Sin Kurth enfrente, la corrida es KurthWorkflows.correr con programada: true: desde el 26 sep, el
//  replay exacto (KurthWorkflowsReplay.swift) en pestañas propias en segundo plano, sin pedir permiso
//  ni confirmación (Kurth: "los programados siempre van en sin permisos porque replican lo que el
//  usuario hizo"); si un paso no aparece lo resuelve el agente en "sin restricciones" mientras dura.
//  Al terminar, una notificación con el resumen; si falla, en qué paso.
//  El permiso de notificaciones se pide la primera vez que se programa algo, no al abrir Nook.
//  kurth.workflowsProgramados = false pausa todo sin borrar reglas.
//

import AppKit
import Foundation
import UserNotifications

extension KurthWorkflows {
    /// Cuánto tarde todavía cuenta como a tiempo (la Task puede despertar unos segundos después).
    static let gracia: TimeInterval = 120

    func arrancarProgramador() {
        revisarAlAbrir()
        reprogramar()
        guard observadoresDelSistema.isEmpty else { return }
        let alCambiar: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { KurthWorkflows.shared.reprogramar() }
        }
        observadoresDelSistema = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: alCambiar),
            NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main, using: alCambiar),
            NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: alCambiar),
        ]
    }

    /// Al abrir Nook: lo que se pasó mientras estaba cerrado queda como saltado, y cada regla activa
    /// recalcula su próxima corrida desde ahora.
    private func revisarAlAbrir() {
        let ahora = Date()
        var saltadas: [String] = []
        for var wf in tienda.todos() {
            guard var p = wf.programacion, p.activa else { continue }
            if let prevista = p.proxima, prevista < ahora.addingTimeInterval(-Self.gracia) {
                p.saltada = prevista
                wf.corridas.append(KurthWorkflowCorrida(inicio: prevista, estado: .saltada, programada: true, fin: prevista,
                                                        resumen: "Nook estaba cerrado o la Mac dormida"))
                saltadas.append(wf.titulo)
            }
            if p.proxima == nil || p.proxima! < ahora { p.proxima = p.siguiente(despuesDe: ahora) }
            if p.frecuencia == .unaVez && p.proxima == nil { p.activa = false }
            wf.programacion = p
            try? tienda.guardar(wf)
        }
        recargar()
        if !saltadas.isEmpty {
            notificar(saltadas.count == 1 ? "Se saltó «\(saltadas[0])»" : "Se saltaron \(saltadas.count) workflows",
                      "Nook estaba cerrado a la hora. Ábrelo en Workflows para correrlo ahora.")
        }
    }

    /// Duerme hasta la corrida más próxima de todas.
    func reprogramar() {
        temporizador?.cancel()
        temporizador = nil
        guard Self.activo, Self.programadosActivos else { return }
        let proximas = workflows.compactMap { wf -> (String, Date)? in
            guard let p = wf.programacion, p.activa, let d = p.proxima else { return nil }
            return (wf.nombre, d)
        }
        guard let (nombre, fecha) = proximas.min(by: { $0.1 < $1.1 }) else { return }
        temporizador = Task { [weak self] in
            let espera = fecha.timeIntervalSinceNow
            if espera > 0 { try? await Task.sleep(for: .seconds(espera)) }
            guard !Task.isCancelled else { return }
            self?.vencio(nombre, prevista: fecha)
        }
    }

    private func vencio(_ nombre: String, prevista: Date) {
        defer { reprogramar() }
        guard var wf = tienda.cargar(nombre), var p = wf.programacion, p.activa, p.proxima == prevista else { return }
        let ahora = Date()
        let tarde = ahora.timeIntervalSince(prevista) > Self.gracia
        p.proxima = p.siguiente(despuesDe: max(ahora, prevista))
        if p.frecuencia == .unaVez { p.activa = false }
        if tarde {
            p.saltada = prevista
            wf.corridas.append(KurthWorkflowCorrida(inicio: prevista, estado: .saltada, programada: true, fin: prevista,
                                                    resumen: "La Mac estaba dormida"))
        }
        wf.programacion = p
        try? tienda.guardar(wf)
        recargar()
        if tarde {
            notificar("Se saltó «\(wf.titulo)» de las \(KurthWorkflowsModelo.hora(prevista))",
                      "La Mac estaba dormida. Ábrelo en Workflows para correrlo ahora.")
        } else {
            try? correr(nombre, valores: p.valores, programada: true)
        }
    }

    // MARK: - Desde el popover y el MCP

    /// Guarda (o cambia) la regla. La próxima corrida se calcula desde ahora.
    func programar(_ nombre: String, _ regla: KurthWorkflowProgramacion) throws {
        guard var wf = tienda.cargar(nombre) else { throw Problema.noExiste(nombre) }
        var p = regla
        p.activa = true
        p.saltada = nil
        p.proxima = p.siguiente(despuesDe: Date())
        wf.programacion = p
        try tienda.guardar(wf)
        recargar()
        reprogramar()
        pedirPermisoDeNotificaciones()
    }

    func desprogramar(_ nombre: String) throws {
        guard var wf = tienda.cargar(nombre) else { throw Problema.noExiste(nombre) }
        wf.programacion = nil
        try tienda.guardar(wf)
        recargar()
        reprogramar()
    }

    /// "Correr ahora" de una corrida saltada, o descartarla.
    func atenderSaltada(_ nombre: String, correrla: Bool) throws {
        guard var wf = tienda.cargar(nombre), var p = wf.programacion else { throw Problema.noExiste(nombre) }
        p.saltada = nil
        wf.programacion = p
        try tienda.guardar(wf)
        recargar()
        if correrla { try correr(nombre, valores: p.valores, programada: false) }
    }

    // MARK: - Notificaciones

    func pedirPermisoDeNotificaciones() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Solo si Kurth ya dio permiso: aquí no se pide (se pide al programar).
    func notificar(_ titulo: String, _ cuerpo: String) {
        Task {
            let centro = UNUserNotificationCenter.current()
            guard await centro.notificationSettings().authorizationStatus == .authorized else { return }
            let contenido = UNMutableNotificationContent()
            contenido.title = titulo
            contenido.body = cuerpo
            contenido.sound = .default
            contenido.threadIdentifier = "kurth-workflows"
            try? await centro.add(UNNotificationRequest(identifier: "kurth-workflow-\(UUID().uuidString)",
                                                        content: contenido, trigger: nil))
        }
    }
}
