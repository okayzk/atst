import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let settingsStore: SettingsStore
    private let updateChecker: UpdateChecker
    private let onQuit: () -> Void

    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(
        settingsStore: SettingsStore,
        updateChecker: UpdateChecker,
        onQuit: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.updateChecker = updateChecker
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            // Plain "atst" text in the menu bar — matches our minimalist
            // tooltip feel and avoids guessing an icon.
            button.title = Branding.appName
            button.image = nil
            button.imagePosition = .noImage
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            button.target = self
            button.action = #selector(toggle)
            button.toolTip = Branding.appName
        }
    }

    @objc private func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            open()
        }
    }

    /// Public entry point — used by the floating tooltip's "Open Settings"
    /// empty-state CTA so the user can flip a translator on without hunting
    /// for the menu bar.
    func openSettings() {
        if let panel, panel.isVisible {
            // Already open — raise it instead of doing nothing, so a second
            // launch still brings the window forward when it sits behind
            // another app.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        open()
    }

    /// Show or hide the menu bar status item. Kept alive while hidden so
    /// the settings panel can still be opened by launching the app again;
    /// `open()` falls back to centring the panel on screen once the status
    /// item has no button window to anchor to.
    func setIconVisible(_ visible: Bool) {
        guard statusItem.isVisible != visible else { return }
        statusItem.isVisible = visible
    }

    private func open() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Opportunistic refresh — checker rate-limits internally so opening
        // settings 50 times in a row only hits the network once per 4h.
        updateChecker.checkInBackground()

        let panelSize = panel.frame.size
        let anchorRect = statusItemAnchorRect()
        let screen = anchorRect.flatMap { rect in
            NSScreen.screens.first(where: { $0.frame.contains(rect.origin) })
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var origin: NSPoint
        if let anchorRect {
            origin = NSPoint(
                x: anchorRect.midX - panelSize.width / 2,
                y: anchorRect.minY - panelSize.height - 6
            )
        } else {
            // Menu bar icon hidden (or not laid out yet): there is no
            // anchor to hang the popover from, so centre it on screen.
            origin = NSPoint(
                x: visible.midX - panelSize.width / 2,
                y: visible.midY - panelSize.height / 2
            )
        }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - panelSize.width - 8))
        origin.y = max(visible.minY + 8, origin.y)

        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitoring()
    }

    /// Screen rect of the status item button, if it is currently in the
    /// menu bar. Nil when the icon is hidden or AppKit hasn't laid the
    /// button out yet.
    private func statusItemAnchorRect() -> NSRect? {
        guard statusItem.isVisible, let button = statusItem.button else { return nil }
        guard let buttonWindow = button.window else { return nil }
        return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func close() {
        stopOutsideClickMonitoring()
        panel?.orderOut(nil)
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel {
                self.close()
            }
            return event
        }
    }

    private func stopOutsideClickMonitoring() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func makePanel() -> NSPanel {
        let content = MenuBarSettingsView(
            settingsStore: settingsStore,
            updateChecker: updateChecker,
            onQuit: onQuit
        )
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = SettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 540),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentViewController = host
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 14
        panel.contentView?.layer?.cornerCurve = .continuous
        panel.contentView?.layer?.masksToBounds = true
        panel.isReleasedWhenClosed = false
        return panel
    }

}

/// Borderless / nonactivating panels don't accept first responder by default,
/// which makes text fields and toggles inside look dimmed and uneditable.
/// Overriding `canBecomeKey` to true lets controls receive focus while we
/// keep the panel out of the app activation list (no dock/app-menu takeover).
private final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
