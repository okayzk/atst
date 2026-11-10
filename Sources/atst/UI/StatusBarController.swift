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
    private var sizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    /// Top-left corner the panel last had. AppKit grows a window upward when
    /// its content size increases, which would push a menu-bar-anchored
    /// panel off the top of the screen; restoring this after a resize keeps
    /// the visible top edge stable.
    private var lastTopLeft: NSPoint?

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

        // Let SwiftUI resolve the page's fitting size before positioning.
        // The root page and its subpages have different heights, and using
        // a stale frame can push the panel past a screen edge.
        syncPanelSize(panel)

        place(panel, near: statusItemAnchorRect())
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitoring()
    }

    /// Position `panel` so the whole window stays inside the visible frame.
    /// With a status item the panel hangs below it; without one (hidden
    /// menu bar icon) it is centred on the screen under the mouse.
    private func place(_ panel: NSPanel, near anchorRect: NSRect?) {
        let size = panel.frame.size
        let screen = anchorRect.flatMap { rect in
            NSScreen.screens.first(where: { $0.frame.contains(rect.origin) })
        } ?? screenUnderMouse() ?? NSScreen.main
        guard let visible = screen?.visibleFrame, visible.width > 0, visible.height > 0 else {
            return
        }

        var origin: NSPoint
        if let anchorRect {
            origin = NSPoint(
                x: anchorRect.midX - size.width / 2,
                y: anchorRect.minY - size.height - 6
            )
        } else {
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
        }
        origin = clamped(origin, size: size, within: visible)
        panel.setFrameOrigin(origin)
        lastTopLeft = NSPoint(x: origin.x, y: origin.y + size.height)
        AppLogger.log("settings panel placed anchored=\(anchorRect != nil) origin=\(origin) size=\(size) visible=\(visible)")
    }

    /// Force the hosting view to resolve its SwiftUI fitting size and apply
    /// it to the window before we position it, keeping the top-left corner
    /// fixed while the height changes.
    private func syncPanelSize(_ panel: NSPanel) {
        guard let view = panel.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        guard fitting.width > 1, fitting.height > 1 else { return }
        let current = panel.frame.size
        guard abs(fitting.width - current.width) > 0.5 || abs(fitting.height - current.height) > 0.5 else {
            return
        }
        let topLeft = lastTopLeft ?? NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(fitting)
        panel.setFrameTopLeftPoint(topLeft)
    }

    /// Keep the panel inside the current screen after SwiftUI changes its
    /// height (navigating from General to a subpage, adding rows, ...).
    private func keepOnScreen(_ panel: NSPanel) {
        guard panel.isVisible else { return }
        if let lastTopLeft {
            panel.setFrameTopLeftPoint(lastTopLeft)
        }
        let frame = panel.frame
        let probe = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame, visible.width > 0, visible.height > 0 else {
            return
        }
        let origin = clamped(frame.origin, size: frame.size, within: visible)
        if origin != frame.origin {
            panel.setFrameOrigin(origin)
        }
        lastTopLeft = NSPoint(x: origin.x, y: origin.y + frame.size.height)
    }

    /// Clamp a window origin so a `size`-sized rect stays fully within
    /// `visible` (with an 8pt breathing margin on every edge).
    private func clamped(_ origin: NSPoint, size: NSSize, within visible: NSRect) -> NSPoint {
        let margin: CGFloat = 8
        let maxX = visible.maxX - size.width - margin
        let maxY = visible.maxY - size.height - margin
        return NSPoint(
            x: max(visible.minX + margin, min(origin.x, maxX)),
            y: max(visible.minY + margin, min(origin.y, maxY))
        )
    }

    /// Screen containing the mouse — the natural choice when the menu bar
    /// icon is hidden and there is no status item to anchor to.
    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
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
        panel.isMovable = true
        // Keep the panel on screen when it loses key/active status. The
        // outside-click monitor below is the intended dismissal path; an
        // activation hiccup (e.g. reopening the app from another app)
        // must not make the just-opened settings window vanish.
        panel.hidesOnDeactivate = false
        // SwiftUI re-sizes the window when the page changes height. Clamp
        // every resize so a taller page never grows through the bottom of
        // the screen.
        sizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            Task { @MainActor in
                guard let self, let panel else { return }
                self.keepOnScreen(panel)
            }
        }
        // Dragging is user-driven, so record the new top-left corner and
        // keep later resizes anchored to it.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            Task { @MainActor in
                guard let self, let panel, panel.isVisible else { return }
                self.lastTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            }
        }
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
