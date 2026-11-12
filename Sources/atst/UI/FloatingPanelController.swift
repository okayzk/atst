import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class FloatingPanelController {
    private let viewModel: TranslatorViewModel
    private let onRefresh: (String) -> Void
    private let onOpenSettings: () -> Void
    private let onSubmitInput: (String) -> Void

    /// Drives the tooltip's max-height constraint so the panel can never
    /// overflow the active screen, and a drag to a position with more
    /// room automatically dismisses the scroll bar.
    private let tooltipLayout = TooltipLayout()

    private lazy var hostingController: NSHostingController<TranslationResultView> = makeHostingController()
    private lazy var panel: TooltipPanel = makePanel()
    private var pinObserver: AnyCancellable?
    private var configObserver: AnyCancellable?
    private var stateObserver: AnyCancellable?
    private var spaceChangeObserver: NSObjectProtocol?
    private var outsideClickGlobalMonitor: Any?
    private var outsideClickLocalMonitor: Any?
    private var panelMoveObserver: NSObjectProtocol?
    private var lastAppliedContentSize: NSSize?

    /// Independent panels created when the user pins a translation. Each is
    /// frozen at the time of pinning and lives until its own × is clicked.
    private var noteControllers: [PinnedNoteController] = []

    init(
        viewModel: TranslatorViewModel,
        onRefresh: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {},
        onSubmitInput: @escaping (String) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onRefresh = onRefresh
        self.onOpenSettings = onOpenSettings
        self.onSubmitInput = onSubmitInput
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.close()
            }
        }
        // Push the "follow across desktops" flag into every live pinned
        // note whenever the user flips it in settings. `removeDuplicates`
        // keeps us from re-applying on every unrelated config save (cache
        // toggle, target language, etc.).
        configObserver = viewModel.$configuration
            .map(\.pinnedNoteFollowsAcrossSpaces)
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                for note in self.noteControllers {
                    note.setFollowsAcrossSpaces(enabled)
                }
            }
        // Key status is only wanted while the editor is up; hand it back the
        // moment the state moves on so the result renders as a normal tooltip.
        stateObserver = viewModel.$state
            .sink { [weak self] state in
                if case .input = state { return }
                self?.relinquishKeyStatus()
            }
    }

    deinit {
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
        }
    }

    func show(anchor: FloatingPanelAnchor = .mouse, activate: Bool = true, animated: Bool = true) {
        ensureSized()

        let topLeft = topLeftPoint(for: anchor, size: panel.frame.size)

        if !panel.isVisible || !animated {
            panel.alphaValue = animated ? 0 : 1
        }
        panel.setFrameTopLeftPoint(topLeft)
        // First cap of the session — happens before the alpha-in animation
        // so the very first render is already bounded.
        updateMaxContentHeight()

        if activate {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            panel.orderFrontRegardless()
        }

        if animated, panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }

        startDismissalMonitors()
        startPanelMoveObserver()
        observePinState()
    }

    func close() {
        pinObserver = nil
        stopDismissalMonitors()
        stopPanelMoveObserver()
        viewModel.pinned = false
        panel.allowsKeyStatus = false
        panel.orderOut(nil)
    }

    /// Esc handler fed by the global hotkey tap. After ⌥D the panel is
    /// shown without becoming key, so a local key monitor would never see Esc.
    @discardableResult
    func closeIfVisible() -> Bool {
        guard panel.isVisible else { return false }
        close()
        return true
    }

    /// Manual-entry mode. The panel becomes key so the editor takes
    /// keystrokes, but the app is not activated — a nonactivating panel
    /// receives keys while the user's app stays frontmost, and skipping
    /// activation avoids the focus-switch flash.
    func showInput(anchor: FloatingPanelAnchor) {
        viewModel.showInput()
        panel.allowsKeyStatus = true
        show(anchor: anchor, activate: false)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Reopen the editor for a finished manual translation. The panel is
    /// already on screen, so this only swaps the state and takes key status;
    /// no repositioning, no dismissal-monitor churn.
    func editSource(_ source: String, previous: TextSegments) {
        viewModel.showInput(prefill: source, previous: previous)
        panel.allowsKeyStatus = true
        panel.makeKeyAndOrderFront(nil)
    }

    /// A key window renders Liquid Glass in its clear "active" form, so the
    /// read-only tooltip must not be key. Re-ordering is the sanctioned way
    /// for a nonactivating panel to give key status back.
    private func relinquishKeyStatus() {
        guard panel.allowsKeyStatus else { return }
        panel.allowsKeyStatus = false
        if panel.isKeyWindow, panel.isVisible {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Pin handling

    private func observePinState() {
        guard pinObserver == nil else { return }
        pinObserver = viewModel.$pinned
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] pinned in
                guard let self else { return }
                if pinned {
                    self.detachAsNote()
                }
            }
    }

    /// Detach the current translation into a pinned note. The note gets its
    /// own `TranslatorViewModel` seeded from this session, so its switch,
    /// collapse, and source-editing controls use the exact same pipeline as
    /// the live tooltip. The live panel then closes, ready for the next
    /// translation.
    private func detachAsNote() {
        guard panel.isVisible,
              let session = viewModel.makeDetachedSession() else {
            viewModel.pinned = false
            return
        }

        let originTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let note = PinnedNoteController(
            session: session,
            followsAcrossSpaces: viewModel.configuration.pinnedNoteFollowsAcrossSpaces,
            onOpenSettings: onOpenSettings
        )
        note.onUserClose = { [weak self, weak note] in
            guard let self, let note else { return }
            self.noteControllers.removeAll { $0 === note }
        }
        note.onUnpin = { [weak self, weak note] in
            guard let self, let note else { return }
            self.unpin(note)
        }
        noteControllers.append(note)
        // The note sits below the live panel's level. Show it instantly at
        // full alpha first, then close the live panel — a plain window swap
        // with no blank/fade frame.
        note.show(at: originTopLeft, animated: false)
        AppLogger.log("detachAsNote: opened pinned note")

        close()
    }

    /// "Unpin" returns a note's session to the normal live tooltip: adopt
    /// its state (and restart unfinished providers) into this controller's
    /// view model, close the note, and show the live panel at the note's
    /// position.
    private func unpin(_ note: PinnedNoteController) {
        let topLeft = note.topLeft
        viewModel.adoptState(from: note.session)

        // Show the live panel above the note first, then dismiss the note.
        // Both steps are instant, so the swap has no fade-out/fade-in gap.
        show(anchor: .topLeft(topLeft), activate: false, animated: false)
        note.closeWithoutCallback()
        noteControllers.removeAll { $0 === note }

        if case .input = viewModel.state {
            panel.allowsKeyStatus = true
            panel.makeKeyAndOrderFront(nil)
        }
        AppLogger.log("unpin: note returned to live tooltip")
    }

    // MARK: - Dismissal monitors

    private func startDismissalMonitors() {
        stopDismissalMonitors()
        outsideClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        outsideClickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel { return event }
            if self.noteControllers.contains(where: { $0.owns(event.window) }) { return event }
            // The per-result switch control opens a SwiftUI Menu in its own
            // pop-up window. Clicking an item there must select it, not count
            // as an outside click that dismisses the tooltip.
            if let window = event.window,
               window.level == .popUpMenu || window.className.localizedCaseInsensitiveContains("menu") {
                return event
            }
            self.close()
            return event
        }
    }

    private func stopDismissalMonitors() {
        [outsideClickGlobalMonitor, outsideClickLocalMonitor].forEach {
            if let m = $0 { NSEvent.removeMonitor(m) }
        }
        outsideClickGlobalMonitor = nil
        outsideClickLocalMonitor = nil
    }

    // MARK: - Panel move observer (drag → recompute max content height)

    private func startPanelMoveObserver() {
        stopPanelMoveObserver()
        // `NSWindow.didMoveNotification` fires after AppKit finishes
        // dragging via `performDrag(with:)`. Recompute the max content
        // height so the ScrollView in the SwiftUI tree can drop the
        // scroll bar if the new position gives enough room — or show it
        // if the user dragged the panel down into less room.
        panelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateMaxContentHeight() }
        }
    }

    private func stopPanelMoveObserver() {
        if let panelMoveObserver {
            NotificationCenter.default.removeObserver(panelMoveObserver)
            self.panelMoveObserver = nil
        }
    }

    // MARK: - Sizing

    private func ensureSized() {
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        guard fitting.width > 1, fitting.height > 1 else { return }
        resizePanel(to: fitting)
    }

    private func handleContentSizeChange(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        resizePanel(to: NSSize(width: size.width, height: size.height))
    }

    private func resizePanel(to newSize: NSSize) {
        guard newSize.width > 1, newSize.height > 1 else { return }
        if let last = lastAppliedContentSize,
           abs(last.width - newSize.width) < 0.25,
           abs(last.height - newSize.height) < 0.25 {
            return
        }
        lastAppliedContentSize = newSize
        panel.setContentSize(newSize)
        // setContentSize is top-anchored (see TooltipPanel), so the new
        // bottom edge may have moved — keep the available-height cap
        // in sync with the new frame.
        updateMaxContentHeight()
    }

    private func makeHostingController() -> NSHostingController<TranslationResultView> {
        let view = TranslationResultView(
            viewModel: viewModel,
            layout: tooltipLayout,
            onClose: { [weak self] in self?.close() },
            onContentSizeChange: { [weak self] size in
                self?.handleContentSizeChange(size)
            },
            onRefresh: { [weak self] sourceText in
                self?.onRefresh(sourceText)
            },
            onOpenSettings: { [weak self] in
                self?.close()
                self?.onOpenSettings()
            },
            onSubmitInput: { [weak self] text in
                self?.onSubmitInput(text)
            },
            onEditSource: { [weak self] source, previous in
                self?.editSource(source, previous: previous)
            }
        )
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.clear.cgColor
        return controller
    }

    /// Recompute the maximum content height based on the panel's current
    /// top edge and the active screen's visible frame. Pushed into the
    /// SwiftUI tree via `tooltipLayout`; the ScrollView inside the view
    /// re-evaluates and shows/hides the scroll bar as needed.
    ///
    /// Called from three places:
    ///   1. After `show()` positions the panel (initial cap).
    ///   2. After `resizePanel(...)` adjusts content size (keep cap in sync
    ///      with new top edge, since `TooltipPanel.setContentSize` is
    ///      top-anchored).
    ///   3. On `NSWindow.didMoveNotification` (user dragged the panel).
    private func updateMaxContentHeight() {
        let topY = panel.frame.maxY
        let probe = NSPoint(x: panel.frame.midX, y: topY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 8pt safety margin to the bottom of the visible area — same as
        // smart positioning uses. Floor at 120pt so the tooltip never
        // becomes uselessly short on tiny screens / edge cases.
        let available = max(120, topY - visible.minY - 8)
        if tooltipLayout.maxContentHeight != available {
            tooltipLayout.maxContentHeight = available
        }
    }

    private func makePanel() -> TooltipPanel {
        let panel = TooltipPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = Branding.appName
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentViewController = hostingController
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.isReleasedWhenClosed = false
        // Movable + nonactivating: the user can drag the panel via the
        // header strip (see `WindowDragHandle`) without stealing app focus
        // from whatever they were translating from. `isMovableByWindowBackground`
        // stays off so dragging the translation body doesn't kidnap text
        // selection.
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        return panel
    }

    /// Smart placement: convert the anchor to a rect, then try candidate
    /// positions (right → below → above → left) and pick the first one
    /// that fully fits the screen's visible area. Falls back to the
    /// largest-area-clamped position when none fully fit (e.g. a huge
    /// tooltip on a small external display).
    ///
    /// This replaces the previous "just offset from the anchor point and
    /// clamp" logic, which often pushed the tooltip away from the source
    /// when the source was near the screen edge.
    private func topLeftPoint(for anchor: FloatingPanelAnchor, size: NSSize) -> NSPoint {
        if case .topLeft(let point) = anchor {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return clamp(topLeft: point, size: size, frame: visible)
        }

        let anchorRect = self.anchorRect(for: anchor)
        let probe = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let candidates = candidatePositions(anchor: anchorRect, size: size)
        for candidate in candidates where fitsInside(topLeft: candidate, size: size, frame: visible) {
            return candidate
        }
        // Nothing fits cleanly — pick whichever candidate maximises on-screen
        // area and clamp it to keep at least an edge visible.
        let best = candidates.max(by: { onScreenArea(topLeft: $0, size: size, frame: visible) < onScreenArea(topLeft: $1, size: size, frame: visible) }) ?? candidates[0]
        return clamp(topLeft: best, size: size, frame: visible)
    }

    private func anchorRect(for anchor: FloatingPanelAnchor) -> NSRect {
        switch anchor {
        case .mouse:
            let p = NSEvent.mouseLocation
            return NSRect(x: p.x, y: p.y, width: 1, height: 1)
        case .point(let p):
            return NSRect(x: p.x, y: p.y, width: 1, height: 1)
        case .rect(let r):
            return r
        case .topLeft(let p):
            return NSRect(origin: p, size: .zero)
        }
    }

    private func candidatePositions(anchor: NSRect, size: NSSize) -> [NSPoint] {
        let gap: CGFloat = 8
        // Position the panel's top-left such that the panel sits on each side
        // of the anchor with `gap` spacing. macOS y axis points up, so:
        //   - top-of-panel = topLeft.y
        //   - bottom-of-panel = topLeft.y - size.height
        return [
            // Right of anchor, aligned to anchor's top edge
            NSPoint(x: anchor.maxX + gap, y: anchor.maxY),
            // Below anchor, aligned to anchor's left edge
            NSPoint(x: anchor.minX,       y: anchor.minY - gap),
            // Above anchor, aligned to anchor's left edge
            NSPoint(x: anchor.minX,       y: anchor.maxY + size.height + gap),
            // Left of anchor, aligned to anchor's top edge
            NSPoint(x: anchor.minX - size.width - gap, y: anchor.maxY)
        ]
    }

    private func fitsInside(topLeft: NSPoint, size: NSSize, frame: NSRect) -> Bool {
        let panelRect = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        return frame.contains(panelRect)
    }

    private func onScreenArea(topLeft: NSPoint, size: NSSize, frame: NSRect) -> CGFloat {
        let panelRect = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        let overlap = frame.intersection(panelRect)
        return overlap.isEmpty ? 0 : overlap.width * overlap.height
    }

    private func clamp(topLeft: NSPoint, size: NSSize, frame: NSRect) -> NSPoint {
        let minX = frame.minX + 8
        let maxX = frame.maxX - size.width - 8
        let minTop = frame.minY + size.height + 8
        let maxTop = frame.maxY - 8
        let x = min(max(topLeft.x, minX), max(minX, maxX))
        let y = min(max(topLeft.y, minTop), max(minTop, maxTop))
        return NSPoint(x: x, y: y)
    }
}

enum FloatingPanelAnchor {
    case mouse
    case point(NSPoint)
    case rect(NSRect)
    /// Exact top-left placement, used when a pinned note returns to the
    /// live tooltip so it doesn't jump to a computed side of an anchor.
    case topLeft(NSPoint)
}

/// The expand / collapse animation is owned entirely by SwiftUI. AppKit just
/// follows instantly with a top-left anchor — no AppKit animation clock to
/// fight against. Result: one driver, smooth drawer feel.
private final class TooltipPanel: NSPanel {
    /// Key status is granted only while the manual-input editor needs to
    /// type. Everywhere else the panel stays non-key: a key window renders
    /// Liquid Glass in its clear "active" form, and clicking the header to
    /// drag would otherwise flip the tooltip into that look.
    var allowsKeyStatus = false
    override var canBecomeKey: Bool { allowsKeyStatus }

    override func setContentSize(_ newSize: NSSize) {
        let currentFrame = frame
        let topLeftY = currentFrame.maxY
        let newFrame = NSRect(
            x: currentFrame.minX,
            y: topLeftY - newSize.height,
            width: newSize.width,
            height: newSize.height
        )
        if newFrame == currentFrame { return }
        setFrame(newFrame, display: true, animate: false)
    }
}

// MARK: - Pinned note window

/// A pinned note is a full translation session, not a frozen snapshot. It
/// owns a detached `TranslatorViewModel`, so the shared
/// `TranslationResultView` gives it the same provider switch, collapse,
/// source editing, refresh and copy controls as the live tooltip. Unpinning
/// hands the session back to `FloatingPanelController`'s live view model.
@MainActor
private final class PinnedNoteController {
    let session: TranslatorViewModel

    private let panel: TooltipPanel
    private let hostingController: NSHostingController<TranslationResultView>
    private let layout = TooltipLayout()
    private var lastAppliedContentSize: NSSize?
    private var stateObserver: AnyCancellable?
    private var moveObserver: NSObjectProtocol?

    var onUserClose: (() -> Void)?
    var onUnpin: (() -> Void)?

    var topLeft: NSPoint {
        NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    init(
        session: TranslatorViewModel,
        followsAcrossSpaces: Bool,
        onOpenSettings: @escaping () -> Void
    ) {
        self.session = session

        var dismissAction: () -> Void = {}
        var sizeAction: (CGSize) -> Void = { _ in }
        var unpinAction: () -> Void = {}

        let view = TranslationResultView(
            viewModel: session,
            layout: layout,
            onClose: { dismissAction() },
            onContentSizeChange: { sizeAction($0) },
            onRefresh: { [weak session] source in
                guard let session else { return }
                session.translateText(source, bypassCache: true)
            },
            onOpenSettings: onOpenSettings,
            onSubmitInput: { [weak session] text in
                guard let session else { return }
                session.translateText(text, bypassCache: false, sourceEditable: true)
            },
            onEditSource: { [weak session] source, previous in
                guard let session else { return }
                session.showInput(prefill: source, previous: previous)
            },
            isPinnedNote: true,
            onUnpin: { unpinAction() },
            surfaceBorder: .accent
        )
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        self.hostingController = host

        let panel = TooltipPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(Branding.appName) note"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = Self.collectionBehavior(followsAcrossSpaces: followsAcrossSpaces)
        panel.contentViewController = host
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.isReleasedWhenClosed = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        self.panel = panel

        dismissAction = { [weak self] in self?.close() }
        sizeAction = { [weak self] size in self?.handleContentSize(size) }
        unpinAction = { [weak self] in self?.onUnpin?() }

        stateObserver = session.$state.sink { [weak self] state in
            guard let self else { return }
            if case .input = state {
                self.panel.allowsKeyStatus = true
                self.panel.makeKeyAndOrderFront(nil)
            } else {
                self.panel.allowsKeyStatus = false
                if self.panel.isKeyWindow {
                    self.panel.resignKey()
                }
            }
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateMaxContentHeight() }
        }
    }

    func owns(_ window: NSWindow?) -> Bool { window === panel }

    func show(at topLeft: NSPoint, animated: Bool = true) {
        // Resolve the note's real content size *before* anchoring it, then
        // keep the top-left corner fixed across every later resize. Doing
        // it the other way around let `setContentSize` grow the window
        // upward from its bottom-left origin, which is the pin "jump".
        updateMaxContentHeight()
        ensureSized()
        panel.setFrameTopLeftPoint(topLeft)
        panel.alphaValue = animated ? 0 : 1
        panel.orderFrontRegardless()
        guard animated else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        closeWithoutCallback()
        onUserClose?()
    }

    func closeWithoutCallback() {
        session.cancelActiveTranslations()
        stateObserver?.cancel()
        stateObserver = nil
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
        panel.orderOut(nil)
    }

    /// Re-applies the Spaces-following collection behavior. Called when
    /// the user flips the toggle in settings so live notes update without
    /// needing to be re-pinned.
    func setFollowsAcrossSpaces(_ enabled: Bool) {
        panel.collectionBehavior = Self.collectionBehavior(followsAcrossSpaces: enabled)
    }

    private func ensureSized() {
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        guard fitting.width > 1, fitting.height > 1 else { return }
        resizePanel(to: fitting)
    }

    private func handleContentSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        resizePanel(to: NSSize(width: size.width, height: size.height))
    }

    private func resizePanel(to newSize: NSSize) {
        if let last = lastAppliedContentSize,
           abs(last.width - newSize.width) < 0.25,
           abs(last.height - newSize.height) < 0.25 {
            return
        }
        lastAppliedContentSize = newSize
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(newSize)
        panel.setFrameTopLeftPoint(topLeft)
        updateMaxContentHeight()
    }

    private func updateMaxContentHeight() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let topY = panel.frame.maxY
        let available = max(120, topY - visible.minY - 8)
        if layout.maxContentHeight != available {
            layout.maxContentHeight = available
        }
    }

    /// `.fullScreenAuxiliary` keeps the note visible when another app is
    /// in fullscreen. `.canJoinAllSpaces` (only when the user opts in)
    /// makes it follow across desktops / Spaces; `.stationary` pairs with
    /// it to skip the parallax slide during Mission Control transitions.
    private static func collectionBehavior(followsAcrossSpaces: Bool) -> NSWindow.CollectionBehavior {
        if followsAcrossSpaces {
            return [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
        return [.fullScreenAuxiliary]
    }
}
