// Licensed under GPL-3.0. See LICENSE.
//
//  KurthCapturas.swift
//  Nook (rama kurth)
//
//  La última imagen de cada pestaña, para lo que necesita ver una pestaña que no está a la vista:
//  deslizar la cápsula de la dirección (la página de al lado entra siguiendo los dedos) y la
//  cuadrícula de pestañas. WebKit solo dibuja la página que se ve; las demás se muestran como se
//  vieron por última vez, así que la captura se toma cuando una pestaña está a la vista: al
//  llegar a ella y al terminar de cargar.
//
//  Se guardan como JPEG de 1400 px de ancho (≈150 KB): 40 pestañas en memoria son unos 6 MB; sin
//  comprimir serían ~4 MB cada una. La página entera se decodifica solo al deslizar; la cuadrícula
//  usa miniaturas de 600 px que ImageIO decodifica ya reducidas y que el sistema puede soltar si
//  falta memoria (NSCache). También van a disco, en Caches/<bundle>/Capturas: sin eso, cada vez
//  que Nook reiniciaba la cuadrícula salía con puros íconos. Las de más de 30 días se borran al
//  abrir Nook.
//

import AppKit
import ImageIO
import Observation
import WebKit

@MainActor
@Observable
final class KurthCapturas {
    static let shared = KurthCapturas()

    /// Observado: una miniatura a la vista se actualiza cuando llega su captura.
    private var datos: [UUID: Data] = [:]
    /// Del más viejo al más reciente, para soltar el más viejo al pasar del tope.
    @ObservationIgnored private var orden: [UUID] = []
    @ObservationIgnored private let tope = 40
    @ObservationIgnored private let miniaturas = NSCache<NSUUID, NSImage>()

    private static let carpeta: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Nook").appendingPathComponent("Capturas")
    }()

    private static func archivo(_ id: UUID) -> URL { carpeta.appendingPathComponent(id.uuidString + ".jpg") }

    init() {
        let carpeta = Self.carpeta
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
            let limite = Date().addingTimeInterval(-30 * 86_400)
            let archivos = (try? FileManager.default.contentsOfDirectory(at: carpeta, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for archivo in archivos {
                let fecha = (try? archivo.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let fecha, fecha < limite { try? FileManager.default.removeItem(at: archivo) }
            }
        }
    }

    /// De memoria, o de disco si es de antes de abrir Nook (sin pasarla a memoria: esto se llama
    /// al dibujar y ahí no se cambia estado observado).
    private func jpeg(_ id: UUID) -> Data? {
        datos[id] ?? (try? Data(contentsOf: Self.archivo(id)))
    }

    /// A tamaño de página, para deslizar.
    func imagen(_ id: UUID) -> NSImage? {
        jpeg(id).flatMap(NSImage.init(data:))
    }

    /// Para la cuadrícula: 600 px de ancho, decodificada una vez.
    func miniatura(_ id: UUID) -> NSImage? {
        // Leer `datos[id]` también con la hecha: así la celda se vuelve a dibujar cuando llegue una
        // captura nueva de esa pestaña (capturar() suelta la vieja de la caché).
        if let hecha = miniaturas.object(forKey: id as NSUUID) { _ = datos[id]; return hecha }
        guard let datos = jpeg(id) else { return nil }
        let opciones: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 600]
        guard let fuente = CGImageSourceCreateWithData(datos as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(fuente, 0, opciones as CFDictionary) else { return nil }
        let imagen = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        miniaturas.setObject(imagen, forKey: id as NSUUID)
        return imagen
    }

    /// Toma la imagen de la página tal como se ve. Sin ventana o sin tamaño no hay qué capturar.
    func capturar(_ webView: WKWebView, id: UUID) async {
        guard webView.window != nil, webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        let config = WKSnapshotConfiguration()
        // 700 pt: 1400 px en pantalla Retina, suficiente para una página a pantalla completa en
        // movimiento y de sobra para una miniatura.
        config.snapshotWidth = NSNumber(value: min(webView.bounds.width, 700))
        guard let imagen = try? await webView.takeSnapshot(configuration: config) else { return }
        // Comprimir toma ~15 ms: fuera del hilo principal.
        let destino = Self.archivo(id)
        let jpeg = await Task.detached(priority: .utility) {
            let jpeg = KurthAgentInput.jpeg(imagen, ladoMaximo: 1400)
            try? jpeg?.write(to: destino, options: .atomic)
            return jpeg
        }.value
        guard let jpeg else { return }
        miniaturas.removeObject(forKey: id as NSUUID)
        datos[id] = jpeg
        orden.removeAll { $0 == id }
        orden.append(id)
        while orden.count > tope { datos[orden.removeFirst()] = nil }
    }
}
