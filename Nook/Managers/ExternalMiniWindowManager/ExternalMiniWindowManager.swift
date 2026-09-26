// Licensed under GPL-3.0. See LICENSE.
//
//  ExternalMiniWindowManager.swift
//  Nook
//
//  Created by Jonathan Caudill on 26/08/2025.
//

import SwiftUI
import WebKit
import AppKit
import Combine
import NookWeb

/// Mini windows: a link from another app, or a sign-in popup that keeps `window.opener`, shown
/// as a detached page in its own small window until it closes or moves to a tab.
@MainActor
final class ExternalMiniWindowManager {
    private weak var browserManager: BrowserManager?
    private var controllers: [UUID: MiniBrowserWindowController] = [:]

    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
    }

    /// A link from another app, in the data store of the active window's space.
    func present(url: URL) {
        guard let browserManager else { return }
        let window = browserManager.windowRegistry?.activeWindow
        let profile = window.flatMap { window in
            window.isIncognito
                ? window.ephemeralProfile
                : window.spaceID.flatMap { browserManager.tabs.profile(forSpace: $0) }
        } ?? browserManager.currentProfile
        guard let profile else { return }
        present(browserManager.tabs.openDetached(url: url, profile: profile, in: window))
    }

    func present(_ page: PageSession) {
        guard let browserManager else { return }
        let controller = MiniBrowserWindowController(
            page: page,
            targetSpaceName: {
                let tabs = browserManager.tabs
                let space = browserManager.windowRegistry?.activeWindow?.spaceID.flatMap { tabs.space($0) }
                    ?? tabs.orderedSpaces.first
                return space?.name ?? "Current Space"
            }(),
            adoptAction: { [weak self] in self?.adopt(page) },
            onClose: { [weak self, weak browserManager] in
                self?.controllers[page.itemID] = nil
                browserManager?.tabs.endDetached(page)
            },
            gradientColorManager: browserManager.gradientColorManager
        )
        page.onClose = { [weak controller] in controller?.close() }
        controllers[page.itemID] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func adopt(_ page: PageSession) {
        guard let browserManager, let window = browserManager.windowRegistry?.activeWindow else { return }
        browserManager.tabs.adopt(page, in: window)
        controllers[page.itemID]?.close()
    }
}

// MARK: - Mini Browser Window Controller

private extension NSToolbarItem.Identifier {
    static let miniOpenInSpace = NSToolbarItem.Identifier("com.nook.miniwindow.openInSpace")
    static let miniShare = NSToolbarItem.Identifier("com.nook.miniwindow.share")
}

/// Carries ⌘O for "open in space": a toolbar item cannot hold a key equivalent,
/// and the window is not part of the app's menu-bar command tree.
final class MiniBrowserWindow: NSWindow {
    var openInSpaceAction: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "o" {
            openInSpaceAction?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class MiniBrowserWindowController: NSWindowController, NSWindowDelegate {
    private let page: PageSession
    private let targetSpaceName: String
    private let adoptAction: () -> Void
    private let onClose: () -> Void
    private var titleObserver: AnyCancellable?

    private static let maximumSize = NSSize(width: 1280, height: 900)
    private static let minimumSize = NSSize(width: 640, height: 480)

    /// Three quarters of the screen, capped so it still reads as a small window on large displays.
    private static var defaultSize: NSSize {
        let visible = NSScreen.main?.visibleFrame.size ?? maximumSize
        return NSSize(
            width: max(minimumSize.width, min(maximumSize.width, visible.width * 0.75)),
            height: max(minimumSize.height, min(maximumSize.height, visible.height * 0.85))
        )
    }

    /// kurth: el tamaño que pide la página (acotado al 90 % de la ventana que la abrió y al máximo);
    /// sin tamaño pedido, 60 × 70 % de esa ventana con tope de 900 × 720, no 75 % de la pantalla.
    private static func initialSize(requested: CGSize?, parent: NSWindow?) -> NSSize {
        let bounds = parent?.frame.size ?? NSScreen.main?.visibleFrame.size ?? maximumSize
        let limit = NSSize(width: min(maximumSize.width, bounds.width * 0.9),
                           height: min(maximumSize.height, bounds.height * 0.9))
        let wanted = requested.flatMap { $0.width > 0 && $0.height > 0 ? NSSize(width: $0.width, height: $0.height) : nil }
            ?? NSSize(width: min(900, bounds.width * 0.6), height: min(720, bounds.height * 0.7))
        return NSSize(width: max(minimumSize.width, min(limit.width, wanted.width)),
                      height: max(minimumSize.height, min(limit.height, wanted.height)))
    }

    init(
        page: PageSession, targetSpaceName: String, adoptAction: @escaping () -> Void,
        onClose: @escaping () -> Void, gradientColorManager: GradientColorManager
    ) {
        self.page = page
        self.targetSpaceName = targetSpaceName
        self.adoptAction = adoptAction
        self.onClose = onClose

        let contentView = MiniBrowserWindowView(page: page)
            .environmentObject(gradientColorManager)

        let hostingController = NSHostingController(rootView: contentView)
        let parent = NSApp.keyWindow ?? NSApp.mainWindow // kurth: la ventana del navegador que la abrió
        let size = Self.initialSize(requested: page.kurthTamañoPedido, parent: parent)
        let window = MiniBrowserWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumSize
        // Without this the hosting controller shrinks the window to the view's minimum size.
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.setContentSize(size)
        // kurth: centrada sobre la ventana que la abrió, no sobre la pantalla.
        if let parentFrame = parent?.frame {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: parentFrame.midX - frame.width / 2, y: parentFrame.midY - frame.height / 2))
        } else {
            window.center()
        }

        super.init(window: window)

        window.delegate = self
        window.openInSpaceAction = adoptAction
        window.subtitle = page.profile?.name ?? "Default"
        installToolbar(on: window)
        observeNavigationState(for: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    @objc private func openInSpace(_ sender: Any?) {
        adoptAction()
    }

    // MARK: - Toolbar

    private func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "com.nook.miniwindow.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .unified
        window.toolbar = toolbar
    }

    /// Mirrors the page into the window's title and the space into its subtitle,
    /// so the toolbar carries no label views of its own.
    private func observeNavigationState(for window: NSWindow) {
        window.title = page.url.host() ?? page.url.absoluteString
        titleObserver = page.webView?.publisher(for: \.url)
            .compactMap { $0 }
            .sink { [weak window] url in
                window?.title = url.host() ?? url.absoluteString
            }
    }
}

extension MiniBrowserWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .miniOpenInSpace, .miniShare]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .miniShare:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: itemIdentifier)
            item.delegate = self
            item.toolTip = "Share"
            return item
        case .miniOpenInSpace:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.title = "Open in \(targetSpaceName)"
            item.toolTip = "Open this page as a tab in \(targetSpaceName) (⌘O)"
            item.isBordered = true
            item.target = self
            item.action = #selector(openInSpace(_:))
            return item
        default:
            return nil
        }
    }
}

extension MiniBrowserWindowController: NSSharingServicePickerToolbarItemDelegate {
    /// The SDK declares this requirement `NS_SWIFT_UI_ACTOR`, so it is already main-actor
    /// isolated. Marking it `nonisolated` forced a `MainActor.assumeIsolated` whose executor
    /// check segfaults in the concurrency runtime on macOS 27 (26A428) during toolbar validation.
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        [page.url]
    }
}
