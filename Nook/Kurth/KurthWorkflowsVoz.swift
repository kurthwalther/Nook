// Licensed under GPL-3.0. See LICENSE.
//
//  KurthWorkflowsVoz.swift
//  Nook (rama kurth)
//
//  Lo que Kurth dice mientras graba un workflow ("y aquí siempre filtro por la semana pasada"),
//  transcrito en la Mac con SFSpeechRecognizer: requiresOnDeviceRecognition = true, así que el audio
//  no sale de la máquina. Si el dictado sin conexión de español (México) no está descargado, no se
//  cae al servidor de Apple: se dice que falta y el micrófono queda apagado.
//
//  Cómo se parte en frases: el reconocedor devuelve siempre el texto completo desde que empezó y lo
//  va corrigiendo. Una frase se cierra cuando Kurth hace una pausa de 1.4 s; se manda lo nuevo desde
//  la última frase (contado por palabras, que aguantan mejor que los caracteres las correcciones de
//  palabras anteriores), con la hora en que empezó a decirla. Así la frase queda intercalada con los
//  clics que hizo mientras hablaba.
//
//  El audio llega en el hilo de audio de Core Audio, no en el principal: la toma del micrófono y el
//  manejador del reconocedor se arman en funciones nonisolated y solo cruzan al principal con Task.
//

import AVFoundation
import Foundation
import Observation
import Speech

@MainActor
@Observable
final class KurthWorkflowsVoz {
    private(set) var encendida = false
    private(set) var error: String?
    /// Lo que se está diciendo ahora, todavía sin cerrar (el aviso lo enseña en gris).
    private(set) var parcial = ""

    /// Cada frase cerrada, con la hora en que empezó.
    @ObservationIgnored var alFragmento: ((String, Date) -> Void)?

    @ObservationIgnored private var motor: AVAudioEngine?
    @ObservationIgnored private var reconocedor: SFSpeechRecognizer?
    @ObservationIgnored private var tarea: SFSpeechRecognitionTask?
    @ObservationIgnored private let caja = CajaDePedido()
    @ObservationIgnored private var palabras: [String] = []
    @ObservationIgnored private var cerradas = 0
    @ObservationIgnored private var inicioDeFrase: Date?
    @ObservationIgnored private var pausa: Task<Void, Never>?
    /// Cada tarea nueva sube el número: lo que llegue de una tarea vieja se ignora.
    @ObservationIgnored private var generacion = 0
    @ObservationIgnored private var fallosSeguidos: [Date] = []

    private static let pausaDeFrase: Duration = .milliseconds(1400)

    func encender() async {
        guard !encendida else { return }
        error = nil
        guard await Self.permisoDeDictado() else {
            error = "Sin permiso de dictado. Ajustes del Sistema › Privacidad › Reconocimiento de voz."
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "Sin permiso de micrófono. Ajustes del Sistema › Privacidad › Micrófono."
            return
        }
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: "es-MX")) else {
            error = "La Mac no tiene dictado en español (México)."
            return
        }
        guard r.supportsOnDeviceRecognition else {
            error = "Falta el dictado sin conexión en español (México): Ajustes del Sistema › Teclado › Dictado."
            return
        }
        reconocedor = r
        let motor = AVAudioEngine()
        let entrada = motor.inputNode
        let formato = entrada.outputFormat(forBus: 0)
        guard formato.sampleRate > 0, formato.channelCount > 0 else {
            error = "No encontré micrófono."
            return
        }
        Self.tomar(entrada, formato: formato, caja: caja)
        motor.prepare()
        do {
            try motor.start()
        } catch {
            entrada.removeTap(onBus: 0)
            self.error = "El micrófono no arrancó: \(error.localizedDescription)"
            return
        }
        self.motor = motor
        encendida = true
        empezarTarea()
    }

    func apagar() {
        guard encendida else { return }
        encendida = false
        cerrarFrase()
        generacion += 1
        motor?.inputNode.removeTap(onBus: 0)
        motor?.stop()
        motor = nil
        caja.pedido?.endAudio()
        caja.poner(nil)
        tarea?.cancel()
        tarea = nil
        parcial = ""
    }

    // MARK: - Reconocimiento

    private func empezarTarea() {
        guard encendida, let reconocedor else { return }
        let pedido = SFSpeechAudioBufferRecognitionRequest()
        pedido.requiresOnDeviceRecognition = true
        pedido.shouldReportPartialResults = true
        pedido.addsPunctuation = true
        pedido.taskHint = .dictation
        caja.poner(pedido)
        palabras = []
        cerradas = 0
        generacion += 1
        let esta = generacion
        tarea = Self.reconocer(reconocedor, pedido) { [weak self] texto, final, fallo in
            Task { @MainActor in self?.recibir(texto, final: final, fallo: fallo, generacion: esta) }
        }
    }

    private func recibir(_ texto: String?, final: Bool, fallo: String?, generacion esta: Int) {
        guard esta == generacion, encendida else { return }
        if let texto {
            palabras = texto.split(whereSeparator: \.isWhitespace).map(String.init)
            if palabras.count > cerradas {
                if inicioDeFrase == nil { inicioDeFrase = Date() }
                parcial = palabras[cerradas...].joined(separator: " ")
                pausa?.cancel()
                pausa = Task { [weak self] in
                    try? await Task.sleep(for: Self.pausaDeFrase)
                    guard !Task.isCancelled else { return }
                    self?.cerrarFrase()
                }
            }
        }
        guard final || fallo != nil else { return }
        cerrarFrase()
        // La tarea terminó sola (silencio largo o un error pasajero): otra sobre el mismo micrófono.
        // Tres fallos en 10 s ya no es pasajero: se apaga y se dice.
        if let fallo {
            let ahora = Date()
            fallosSeguidos = fallosSeguidos.filter { ahora.timeIntervalSince($0) < 10 } + [ahora]
            if fallosSeguidos.count >= 3 {
                apagar()
                error = "El dictado se detuvo: \(fallo)"
                return
            }
        }
        empezarTarea()
    }

    private func cerrarFrase() {
        pausa?.cancel()
        pausa = nil
        defer { inicioDeFrase = nil; parcial = "" }
        guard palabras.count > cerradas else { return }
        let frase = palabras[cerradas...].joined(separator: " ")
        cerradas = palabras.count
        alFragmento?(frase, inicioDeFrase ?? Date())
    }

    // MARK: - Fuera del hilo principal

    /// El pedido vigente, compartido con el hilo de audio (que le agrega cada búfer).
    private final class CajaDePedido: @unchecked Sendable {
        private let candado = NSLock()
        private var actual: SFSpeechAudioBufferRecognitionRequest?
        var pedido: SFSpeechAudioBufferRecognitionRequest? { candado.withLock { actual } }
        func poner(_ p: SFSpeechAudioBufferRecognitionRequest?) { candado.withLock { actual = p } }
        func agregar(_ b: AVAudioPCMBuffer) { candado.withLock { actual?.append(b) } }
    }

    nonisolated private static func tomar(_ entrada: AVAudioInputNode, formato: AVAudioFormat, caja: CajaDePedido) {
        entrada.installTap(onBus: 0, bufferSize: 1024, format: formato) { buffer, _ in
            caja.agregar(buffer)
        }
    }

    nonisolated private static func reconocer(_ r: SFSpeechRecognizer, _ p: SFSpeechAudioBufferRecognitionRequest,
                                              _ alResultado: @escaping @Sendable (String?, Bool, String?) -> Void) -> SFSpeechRecognitionTask {
        r.recognitionTask(with: p) { resultado, error in
            alResultado(resultado?.bestTranscription.formattedString, resultado?.isFinal ?? false, error?.localizedDescription)
        }
    }

    nonisolated private static func permisoDeDictado() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}
