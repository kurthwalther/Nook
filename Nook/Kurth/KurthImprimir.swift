// Licensed under GPL-3.0. See LICENSE.
//
//  KurthImprimir.swift
//  Nook (rama kurth)
//
//  Lo que WebKit ya traía y Nook no usaba (revisado el 25 sep con una sonda en el WebKit de la Mac):
//  imprimir (⌘P no hacía nada), exportar como PDF por páginas, guardar la página como archivo web y
//  el tamaño del texto aparte del zoom de la página (⌥⌘+ / ⌥⌘−, como Safari).
//

import AppKit
import UniformTypeIdentifiers
import WebKit
import NookWeb

extension BrowserManager {
    /// La vista web de la pestaña activa en la ventana activa.
    @MainActor var kurthPaginaActiva: WKWebView? {
        guard let ventana = windowRegistry?.activeWindow, let sesion = tabs.activeWindowSession else { return nil }
        return getWebView(for: sesion.itemID, in: ventana.id)
    }

    @MainActor var kurthTituloActivo: String {
        tabs.activeWindowSession?.title ?? "Página"
    }
}

@MainActor
enum KurthImprimir {
    // MARK: - Imprimir y PDF

    static func imprimir(_ webView: WKWebView) {
        correr(webView.printOperation(with: configuracion()), en: webView, conPanel: true)
    }

    /// Por páginas, como "Exportar como PDF" de Safari: la misma operación de imprimir, a un archivo.
    /// (createPDF da una sola página larguísima.)
    static func exportarPDF(_ webView: WKWebView, titulo: String) {
        pedirDestino(para: webView, nombre: titulo, tipo: .pdf) { url in
            let info = configuracion()
            info.jobDisposition = .save
            info.dictionary().setObject(url, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)
            correr(webView.printOperation(with: info), en: webView, conPanel: false)
        }
    }

    /// La página con sus imágenes y estilos en un solo archivo .webarchive, que Safari abre igual.
    static func guardarArchivoWeb(_ webView: WKWebView, titulo: String) {
        pedirDestino(para: webView, nombre: titulo, tipo: .webArchive) { url in
            webView.createWebArchiveData { resultado in
                if case .success(let data) = resultado { try? data.write(to: url, options: .atomic) }
            }
        }
    }

    private static func configuracion() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        for lado in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] { info[keyPath: lado] = 36 }
        return info
    }

    private static func correr(_ operacion: NSPrintOperation, en webView: WKWebView, conPanel: Bool) {
        guard let ventana = webView.window else { return }
        // Sin marco, la operación de WebKit imprime páginas en blanco.
        operacion.view?.frame = webView.bounds
        operacion.showsPrintPanel = conPanel
        operacion.showsProgressPanel = true
        operacion.runModal(for: ventana, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private static func pedirDestino(para webView: WKWebView, nombre: String, tipo: UTType,
                                     _ listo: @escaping @MainActor (URL) -> Void) {
        guard let ventana = webView.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [tipo]
        panel.nameFieldStringValue = limpio(nombre) + "." + (tipo.preferredFilenameExtension ?? "")
        panel.beginSheetModal(for: ventana) { respuesta in
            guard respuesta == .OK, let url = panel.url else { return }
            // Después de que se cierre la hoja: dos hojas seguidas en la misma ventana chocan.
            DispatchQueue.main.async { MainActor.assumeIsolated { listo(url) } }
        }
    }

    /// El título como nombre de archivo: sin diagonales ni dos puntos, y corto.
    private static func limpio(_ titulo: String) -> String {
        let prohibidos = CharacterSet(charactersIn: "/:\\")
        let texto = titulo.components(separatedBy: prohibidos).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String((texto.isEmpty ? "Página" : texto).prefix(80))
    }

    // MARK: - Captura de la página completa

    /// Toda la página de arriba abajo como PNG, no solo lo que se ve: WebKit la da entera como PDF
    /// de una sola hoja (createPDF sin rect) y aquí se pasa a pixeles, a la escala de la pantalla y
    /// con un tope de 16 384 px de alto (arriba de eso muchas apps ya no abren la imagen). Queda en
    /// Descargas y copiada. Devuelve dónde quedó, o nil si no se pudo.
    static func capturarPaginaCompleta(_ webView: WKWebView, titulo: String) async -> URL? {
        await recorrer(webView)
        guard let pdf = try? await webView.pdf(configuration: WKPDFConfiguration()),
              let hoja = NSPDFImageRep(data: pdf) else { return nil }
        var escala = webView.window?.backingScaleFactor ?? 2
        let tope: CGFloat = 16_384
        if hoja.bounds.height * escala > tope { escala = tope / hoja.bounds.height }
        let ancho = Int(hoja.bounds.width * escala), alto = Int(hoja.bounds.height * escala)
        guard ancho > 0, alto > 0,
              let pixeles = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: ancho, pixelsHigh: alto,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        pixeles.size = hoja.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixeles)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: hoja.bounds.size).fill()
        hoja.draw(in: NSRect(origin: .zero, size: hoja.bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = pixeles.representation(using: .png, properties: [:]) else { return nil }

        let fecha = DateFormatter()
        fecha.dateFormat = "yyyy-MM-dd 'a las' HH.mm.ss"
        let descargas = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destino = descargas.appendingPathComponent("Captura de \(limpio(titulo)) \(fecha.string(from: Date())).png")
        guard (try? png.write(to: destino, options: .atomic)) != nil else { return nil }
        // Copiada como imagen, para pegarla directo en un chat o un documento.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        return destino
    }

    /// Recorre la página de arriba abajo antes de capturar: muchas cargan imágenes y fondos solo al
    /// llegar a ellos (lazy loading) y sin esto salían en blanco (ultrajewels, 25 sep). Pasos de una
    /// pantalla cada 150 ms, como mucho 40 pasos, luego espera hasta 1.5 s a que terminen las
    /// imágenes y regresa a donde estaba. En el mundo aislado: la página no lo ve.
    private static func recorrer(_ webView: WKWebView) async {
        let js = """
        const antes = scrollY, espera = (ms) => new Promise(r => setTimeout(r, ms));
        for (const img of document.images) { if (img.loading === 'lazy') img.loading = 'eager'; }
        const paso = Math.max(200, innerHeight * 0.9);
        for (let i = 0; i < 40; i++) {
          const alto = document.documentElement.scrollHeight;
          if (scrollY + innerHeight >= alto - 2) break;
          scrollTo(0, scrollY + paso);
          await espera(150);
        }
        const fin = performance.now() + 1500;
        while (performance.now() < fin && [...document.images].some(i => !i.complete)) await espera(100);
        scrollTo(0, antes);
        await espera(200);
        return true;
        """
        _ = try? await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: KurthCopilot.mundo)
    }

    // MARK: - Tamaño del texto

    /// El factor de texto actual de la página (1 = 100 %).
    static func factorDeTexto(_ webView: WKWebView) -> Double {
        leerDouble(webView, "_textZoomFactor") ?? 1
    }

    /// Agranda o achica solo el texto (el zoom normal escala toda la página). nil lo regresa a 100 %.
    /// Pasos de 10 %, entre 50 % y 300 %, como Safari. No se guarda: es de la página abierta.
    static func tamañoDeTexto(_ webView: WKWebView, mas: Bool?) {
        let actual = leerDouble(webView, "_textZoomFactor") ?? 1
        let nuevo: Double
        switch mas {
        case .none: nuevo = 1
        case .some(true): nuevo = min(actual * 1.1, 3)
        case .some(false): nuevo = max(actual / 1.1, 0.5)
        }
        escribirDouble(webView, "_setTextZoomFactor:", nuevo)
    }

    private static func leerDouble(_ objeto: NSObject, _ nombre: String) -> Double? {
        let selector = NSSelectorFromString(nombre)
        guard objeto.responds(to: selector), let imp = objeto.method(for: selector) else { return nil }
        typealias Lector = @convention(c) (AnyObject, Selector) -> Double
        return unsafeBitCast(imp, to: Lector.self)(objeto, selector)
    }

    private static func escribirDouble(_ objeto: NSObject, _ nombre: String, _ valor: Double) {
        let selector = NSSelectorFromString(nombre)
        guard objeto.responds(to: selector), let imp = objeto.method(for: selector) else { return }
        typealias Escritor = @convention(c) (AnyObject, Selector, Double) -> Void
        unsafeBitCast(imp, to: Escritor.self)(objeto, selector, valor)
    }
}
