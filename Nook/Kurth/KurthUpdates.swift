// Licensed under GPL-3.0. See LICENSE.
//
//  KurthUpdates.swift
//  Nook (rama kurth)
//
//  Este Nook se compila en casa con la rama kurth encima de cada versión oficial. Si Sparkle
//  instalara la versión de upstream, se perderían los cambios; las actualizaciones las trae
//  el script de kurth/, no Sparkle.
//

import Foundation
import Sparkle

extension AppDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        throw NSError(
            domain: "kurth.updates",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Este Nook se actualiza con la rama kurth, no con Sparkle."]
        )
    }
}
