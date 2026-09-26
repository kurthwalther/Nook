// Licensed under GPL-3.0. See LICENSE.
//
//  KurthJalarParaRecargar.swift
//  Nook (rama kurth)
//
//  Jalar para recargar (pull-to-refresh), como Safari 27 en macOS: con la página hasta arriba, jalar
//  con dos dedos hacia abajo estira la página (el rebote elástico de WebKit) y en el hueco aparece
//  una flecha que gira con el jalón. Al pasar el umbral el trackpad da un golpe háptico y la flecha
//  se marca; al soltar ahí, la página se recarga. Si se regresa antes de soltar, no pasa nada.
//
//  No pelea con el rebote ni con los gestos de la capa porque no consume ningún evento:
//  - La distancia es el propio estiramiento de WebKit. Durante el rebote, WebKit reporta un
//    desplazamiento negativo por `_updateScrollGeometryWithContentOffset:contentSize:` (el aviso
//    que ya intercepta KurthPageState). Medido el 26 sep en un WKWebView: -1 … -19 pt mientras se
//    jala y de vuelta a 0 al soltar. Si la página no rebota (un div con scroll propio que no está
//    arriba, `overscroll-behavior: none`, mapas o editores que se quedan la rueda), el
//    desplazamiento no baja de 0 y no hay nada que recargar: se hereda el criterio de WebKit.
//  - Las fases del gesto (dedos puestos, moviéndose, levantados) vienen de `scrollWheel` en
//    FocusableWKWebView, que solo mira y siempre pasa el evento a WebKit. Los gestos que empiezan
//    sobre la cápsula de la dirección se los queda KurthGestosDePestanas antes y nunca llegan aquí.
//  - Solo cuenta con los dedos en el trackpad y si el gesto empezó con la página ya arriba: una
//    subida rápida con inercia que rebota en el tope no recarga. La rueda de un mouse no tiene
//    fases y no hace nada.
//

import AppKit
import ObjectiveC
import WebKit

@MainActor
enum KurthJalarParaRecargar {
    static let ajuste = "kurth.pullToRefresh"
    static let ajusteDistancia = "kurth.pullToRefreshDistancia"
    static let distanciaDefault = 64.0

    static var activo: Bool { UserDefaults.standard.object(forKey: ajuste) as? Bool ?? true }
    /// Puntos de estiramiento para quedar lista (el hueco que se ve entre la barra y la página).
    static var distancia: CGFloat {
        let valor = UserDefaults.standard.object(forKey: ajusteDistancia) as? Double ?? distanciaDefault
        return CGFloat(min(max(valor, 24), 200))
    }

    // MARK: - Estado por vista web

    private final class Estado {
        /// Último desplazamiento vertical tal cual lo da WebKit (negativo durante el rebote).
        var y: CGFloat = 0
        var dedos = false
        /// El gesto empezó con la página arriba.
        var valido = false
        /// Pasó el umbral en este gesto.
        var lista = false
        /// Se soltó lista: la flecha se queda marcada mientras la página regresa.
        var recargando = false
        var indicador: Indicador?
    }

    private static var clave: UInt8 = 0

    private static func estado(_ webView: WKWebView) -> Estado {
        if let e = objc_getAssociatedObject(webView, &clave) as? Estado { return e }
        let e = Estado()
        objc_setAssociatedObject(webView, &clave, e, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return e
    }

    // MARK: - Entradas

    /// Desde FocusableWKWebView.scrollWheel, antes de pasarle el evento a WebKit.
    static func rueda(_ evento: NSEvent, en webView: WKWebView) {
        // La inercia y la rueda del mouse no cuentan.
        guard evento.momentumPhase.isEmpty, !evento.phase.isEmpty else { return }
        let e = estado(webView)
        if evento.phase.contains(.began) {
            e.dedos = true
            e.lista = false
            e.recargando = false
            e.valido = activo && e.y <= 0.5
        } else if evento.phase.contains(.ended) {
            e.dedos = false
            let recargar = e.valido && e.lista
            e.valido = false
            e.lista = false
            if recargar {
                e.recargando = true
                self.recargar(webView)
            }
            dibujar(webView, e)
        } else if evento.phase.contains(.cancelled) {
            e.dedos = false
            e.valido = false
            e.lista = false
            dibujar(webView, e)
        }
    }

    /// Desde KurthPageState, en cada aviso de scroll de WebKit.
    static func desplazamiento(_ y: CGFloat, en webView: WKWebView) {
        let e = estado(webView)
        e.y = y
        guard e.valido || e.indicador?.isHidden == false else { return }
        if e.dedos && e.valido {
            let estirado = max(0, -y)
            if !e.lista && estirado >= distancia {
                e.lista = true
                // levelChange es el golpe de "pasaste un nivel" del Force Touch: el mismo aviso
                // físico que da macOS al cruzar un umbral de presión.
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            } else if e.lista && estirado < distancia * 0.8 {
                // Con margen para que temblar justo en la raya no la prenda y apague.
                e.lista = false
            }
        }
        dibujar(webView, e)
    }

    private static func recargar(_ webView: WKWebView) {
        if let session = (webView as? FocusableWKWebView)?.owningSession {
            session.refresh()
        } else {
            webView.reload()
        }
    }

    // MARK: - La flecha

    private static func dibujar(_ webView: WKWebView, _ e: Estado) {
        let estirado = max(0, -e.y)
        // Aparece solo en un gesto válido; al soltar se va con la página que regresa.
        let mostrar = estirado > 2 && (e.valido || e.indicador?.isHidden == false)
        guard mostrar else {
            e.indicador?.isHidden = true
            e.recargando = false
            return
        }
        let indicador: Indicador
        if let existente = e.indicador, existente.superview === webView {
            indicador = existente
        } else {
            indicador = Indicador()
            webView.addSubview(indicador)
            e.indicador = indicador
        }
        indicador.isHidden = false
        let progreso = min(estirado / distancia, 1)
        let lado: CGFloat = 28
        let arriba = webView.obscuredContentInsets.top
        // En medio del hueco que abre el rebote, entre la barra y la orilla de la página.
        let centroY = arriba + estirado / 2
        let y = webView.isFlipped ? centroY - lado / 2 : webView.bounds.height - centroY - lado / 2
        indicador.frame = CGRect(x: webView.bounds.midX - lado / 2, y: y, width: lado, height: lado)
        indicador.actualizar(progreso: progreso, lista: (e.lista && e.dedos) || e.recargando,
                             oscuro: esOscuro(webView.underPageBackgroundColor))
    }

    /// El hueco se pinta con el color de arriba de la página (KurthPageState lo iguala), no con el
    /// de la app: la flecha se decide por ese fondo. Con los colores dinámicos del sistema, una
    /// página blanca con macOS oscuro daba flecha gris claro sobre blanco.
    private static func esOscuro(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.sRGB) else { return false }
        let luz = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luz < 0.5
    }

    /// Una flecha circular de SF Symbols que gira con el jalón. Sin clics: hitTest devuelve nil.
    private final class Indicador: NSView {
        private let simbolo = CALayer()
        private var estabaLista = false
        private var estabaOscuro: Bool?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(simbolo)
            simbolo.contentsGravity = .center
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            simbolo.frame = bounds
            CATransaction.commit()
        }

        func actualizar(progreso: CGFloat, lista: Bool, oscuro: Bool) {
            let reducir = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if simbolo.contents == nil || lista != estabaLista || oscuro != estabaOscuro {
                simbolo.contents = imagen(lista: lista, oscuro: oscuro)
                simbolo.contentsScale = window?.backingScaleFactor ?? 2
                estabaOscuro = oscuro
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            simbolo.frame = bounds
            // Entra de a poco: invisible en los primeros puntos, completa al 60 % del camino.
            simbolo.opacity = Float(min(1, max(0, (progreso - 0.1) / 0.5)))
            // Tres cuartos de vuelta en todo el camino, en el sentido de la flecha: en la capa (y
            // hacia arriba) un ángulo que baja gira como las manecillas. Lista, queda derecha.
            let angulo = reducir ? 0 : (1 - progreso) * .pi * 1.5
            simbolo.setAffineTransform(CGAffineTransform(rotationAngle: angulo))
            CATransaction.commit()

            // Al quedar lista, un pulso corto; con "reducir movimiento", solo el cambio de color.
            if lista && !estabaLista && !reducir {
                let pulso = CAKeyframeAnimation(keyPath: "transform.scale")
                pulso.values = [1.0, 1.18, 1.0]
                pulso.keyTimes = [0, 0.4, 1]
                pulso.duration = 0.24
                pulso.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
                simbolo.add(pulso, forKey: "pulso")
            }
            estabaLista = lista
        }

        /// Gris (50 %) mientras se jala; casi pleno (85 %) cuando ya recarga al soltar.
        private func imagen(lista: Bool, oscuro: Bool) -> NSImage? {
            let tinta = (oscuro ? NSColor.white : NSColor.black).withAlphaComponent(lista ? 0.85 : 0.5)
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: lista ? .bold : .semibold)
                .applying(.init(paletteColors: [tinta]))
            return NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }
    }
}
