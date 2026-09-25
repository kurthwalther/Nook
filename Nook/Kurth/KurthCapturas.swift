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
//  Se guardan como JPEG de 1400 px de ancho (≈150 KB): 40 pestañas son unos 6 MB; sin comprimir
//  serían ~4 MB cada una. La página entera se decodifica solo al deslizar; la cuadrícula usa
//  miniaturas de 600 px que ImageIO decodifica ya reducidas y que el sistema puede soltar si
//  falta memoria (NSCache).
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

    /// A tamaño de página, para deslizar.
    func imagen(_ id: UUID) -> NSImage? {
        datos[id].flatMap(NSImage.init(data:))
    }

    /// Para la cuadrícula: 600 px de ancho, decodificada una vez.
    func miniatura(_ id: UUID) -> NSImage? {
        guard let datos = datos[id] else { return nil }
        if let hecha = miniaturas.object(forKey: id as NSUUID) { return hecha }
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
        let jpeg = await Task.detached(priority: .utility) { KurthAgentInput.jpeg(imagen, ladoMaximo: 1400) }.value
        guard let jpeg else { return }
        miniaturas.removeObject(forKey: id as NSUUID)
        datos[id] = jpeg
        orden.removeAll { $0 == id }
        orden.append(id)
        while orden.count > tope { datos[orden.removeFirst()] = nil }
    }
}
