// Licensed under GPL-3.0. See LICENSE.
//
//  Appearance.swift
//  Nook
//
//  Created by Maciek Bagiński on 07/12/2025.
//

import NookSettings
import SwiftUI

public struct SettingsAppearanceTab: View {
    @Environment(NookSettingsService.self) var nookSettings
    // kurth: el material de las barras (Nook/Kurth/KurthPanelMaterial.swift). Misma clave y mismo
    // default que allá; el ◐ del encabezado del agente cambia el mismo ajuste.
    @AppStorage("kurth.panelMaterial") private var kurthMaterial = "glass"


    public init() {}

    public var body: some View {
        @Bindable var settings = nookSettings
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                // kurth: el activo queda marcado en el segmento.
                Picker(selection: $kurthMaterial) {
                    Text("Vidrio").tag("glass")
                    Text("Clásico").tag("panel")
                } label: {
                    Text("Material de las barras")
                    Text("Vidrio: Liquid Glass de macOS 26 en el fondo de la ventana y en las barras que salen con el mouse. Clásico: el difuminado de antes.")
                }
                .pickerStyle(.segmented)
            }

            // Every row here is about the Mac window: a sidebar side, the
            // floating URL bar, and a hover preview. None has a touch meaning.
            #if os(macOS)
            Section("Layout") {
                Picker("Sidebar Position", selection: $settings.sidebarPosition) {
                    ForEach(SidebarPosition.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Toggle("Show URL bar in the web view", isOn: $settings.topBarAddressView)
                Toggle("Preview link URL on hover", isOn: $settings.showLinkStatusBar)
            }
            #endif
        }
        .formStyle(.grouped)
    }
}
