import AppKit
import SwiftUI

// MARK: - Shared icon style

/// Every small control icon (refresh, pin, close, switch, collapse, copy)
/// renders through this one style. SF Symbols already share an optical
/// scale and stroke weight at a given point size; forcing them into a
/// common square shrank the tall glyphs (pin, copy, switch) and made their
/// strokes thinner than xmark / chevron. Render them at their natural size
/// instead, inside the same 16×16 hit area.
enum ResultIconStyle {
    static let pointSize: CGFloat = 10
    static let hit: CGFloat = 16
    static let defaultWeight: NSFont.Weight = .medium
    static let defaultFontWeight: Font.Weight = .medium
    static let nsTint: NSColor = .tertiaryLabelColor
    static let tint = Color(nsColor: nsTint)

    /// Outline-heavy glyphs (the pushpin and the copy documents) read
    /// lighter than xmark / chevron at the same weight, so bump just those.
    /// Their ink bounds stay the same; only the strokes thicken.
    static func weight(for name: String) -> NSFont.Weight {
        needsHeavierStroke(name) ? .semibold : defaultWeight
    }

    static func fontWeight(for name: String) -> Font.Weight {
        needsHeavierStroke(name) ? .semibold : defaultFontWeight
    }

    private static func needsHeavierStroke(_ name: String) -> Bool {
        switch name {
        case "pin", "pin.slash", "doc.on.doc", "checkmark":
            return true
        default:
            return false
        }
    }

    /// The AppKit switch button uses the same symbol configuration as the
    /// SwiftUI icons so its glyph can't drift in size or weight.
    static func image(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight(for: name))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }
}

/// One glyph inside a 16×16 hit area. Use `ResultIconButton` for clickable
/// icons; this view is for labels such as the copy feedback checkmark.
struct ResultGlyph: View {
    let systemName: String
    var rotation: Double = 0
    var tint: AnyShapeStyle = AnyShapeStyle(ResultIconStyle.tint)

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: ResultIconStyle.pointSize, weight: ResultIconStyle.fontWeight(for: systemName)))
            .foregroundStyle(tint)
            .rotationEffect(.degrees(rotation))
            .frame(width: ResultIconStyle.hit, height: ResultIconStyle.hit)
            .contentShape(Rectangle())
    }
}

struct ResultIconButton: View {
    let systemName: String
    let help: String
    var rotation: Double = 0
    var tint: AnyShapeStyle = AnyShapeStyle(ResultIconStyle.tint)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ResultGlyph(systemName: systemName, rotation: rotation, tint: tint)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Copy button

/// Copy-to-pasteboard icon button with a 1.2s "copied" checkmark. Owns
/// its own feedback state so every row that needs one doesn't re-implement
/// the timer.
struct CopyButton: View {
    let text: String
    var tooltip: String = L.pick("Copy this", "复制这一条")
    /// Result rows keep the icon invisible until the pointer is over the
    /// row, so a stack of translations reads as text rather than as a
    /// column of identical buttons. The copied checkmark always shows.
    var isVisible: Bool = true

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            resetTask?.cancel()
            copied = true
            resetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if !Task.isCancelled { copied = false }
            }
        } label: {
            ResultGlyph(
                systemName: copied ? "checkmark" : "doc.on.doc",
                tint: copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(ResultIconStyle.tint)
            )
            .opacity(isVisible || copied ? 1 : 0)
        }
        .buttonStyle(.borderless)
        .help(copied ? L.pick("Copied", "已复制") : tooltip)
    }
}

// MARK: - Shared result header

/// Controls shared by every result header, API or AI. One header view keeps
/// the service label, switch menu, and collapse chevron identical across
/// providers; only the content below the header is allowed to differ.
struct SegmentHeaderControls {
    var collapsed: Bool
    var switchTargets: [TranslationProviderID]
    var onToggleCollapse: (() -> Void)?
    var onSwitch: ((TranslationProviderID) -> Void)?
    var onAddAll: (() -> Void)?
    /// AI uses its concrete model name here instead of the generic "AI".
    var displayName: (TranslationProviderID) -> String = { $0.displayName }
}

struct SegmentHeader: View {
    let title: String
    let controls: SegmentHeaderControls?

    var body: some View {
        HStack(spacing: 8) {
            // 服务名 + 渐隐细线：一行就是一个可扫读的分区，多服务结果
            // 之间靠这条线分隔，而不是靠一眼看不出的间距差。
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.18), Color.primary.opacity(0.02)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)

            if let controls {
                if !controls.switchTargets.isEmpty {
                    SwitchMenuButton(
                        switchTargets: controls.switchTargets,
                        onSwitch: { target in controls.onSwitch?(target) },
                        onAddAll: { controls.onAddAll?() },
                        displayName: controls.displayName
                    )
                    .frame(width: 16, height: 16)
                }
                if let onToggleCollapse = controls.onToggleCollapse {
                    Button(action: onToggleCollapse) {
                        ResultGlyph(
                            systemName: controls.collapsed ? "chevron.right" : "chevron.down"
                        )
                    }
                    .buttonStyle(.borderless)
                    .help(controls.collapsed
                          ? L.pick("Expand result", "展开结果")
                          : L.pick("Collapse result", "折叠结果"))
                }
            }
        }
        .frame(minHeight: 16)
    }
}

/// AppKit-backed switch control. SwiftUI's `Menu` draws its label with the
/// control tint (visibly brighter than the other tertiary header icons) and
/// uses the small system menu font; an `NSButton` with `tertiaryLabelColor`
/// and 14 pt menu items matches the result body and the rest of the header.
struct SwitchMenuButton: NSViewRepresentable {
    let switchTargets: [TranslationProviderID]
    let onSwitch: (TranslationProviderID) -> Void
    let onAddAll: () -> Void
    var displayName: (TranslationProviderID) -> String = { $0.displayName }

    func makeNSView(context: Context) -> NSButton {
        let button = HeaderMenuButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.imageScaling = .scaleProportionallyDown
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.toolTip = L.pick("Switch or add services", "切换或添加翻译服务")
        updateImage(button)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.parent = self
        updateImage(nsView)
    }

    private func updateImage(_ button: NSButton) {
        button.image = ResultIconStyle.image("arrow.left.arrow.right")
        button.contentTintColor = ResultIconStyle.nsTint
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        var parent: SwitchMenuButton

        init(_ parent: SwitchMenuButton) {
            self.parent = parent
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let baseFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            let font = baseFont.fontDescriptor.withDesign(.rounded)
                .flatMap { NSFont(descriptor: $0, size: 11) } ?? baseFont
            let textColor = NSColor.labelColor

            for target in parent.switchTargets {
                let title = parent.displayName(target)
                let item = NSMenuItem(
                    title: title,
                    action: #selector(pickService(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = target.rawValue
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.font: font, .foregroundColor: textColor]
                )
                menu.addItem(item)
            }

            menu.addItem(.separator())

            let allTitle = L.pick("All others", "所有其他服务")
            let allItem = NSMenuItem(
                title: allTitle,
                action: #selector(addAll(_:)),
                keyEquivalent: ""
            )
            allItem.target = self
            allItem.attributedTitle = NSAttributedString(
                string: allTitle,
                attributes: [.font: font, .foregroundColor: textColor]
            )
            menu.addItem(allItem)

            let y = sender.isFlipped ? sender.bounds.height + 2 : -2
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: sender)
        }

        @objc private func pickService(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let id = TranslationProviderID(rawValue: raw) else {
                return
            }
            parent.onSwitch(id)
        }

        @objc private func addAll(_ sender: NSMenuItem) {
            parent.onAddAll()
        }
    }
}

private final class HeaderMenuButton: NSButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }
}

// MARK: - API segment rows

/// Stacked API provider rows rendered above the AI block. Shared by the
/// live tooltip and pinned notes; `isSnapshot` swaps the in-flight
/// spinner for a static "(no result)" since a frozen note can't update.
struct APISegmentsBlock: View {
    let segments: [ProviderSegment]
    var isSnapshot = false
    /// Interactive per-result controls, supplied by the live tooltip.
    /// Pinned notes leave this nil and stay read-only.
    var controls: Controls? = nil
    /// The live tooltip renders one row per provider because each row owns
    /// switch/collapse controls. Pinned notes keep the old identical-result
    /// merge ("Google · Microsoft").
    var mergeIdenticalResults = true
    /// Handler for the "Disable" button on a collapsed failure row. nil
    /// (pinned notes) hides the button.
    var onDisable: ((TranslationProviderID) -> Void)? = nil

    struct Controls {
        var collapsedIDs: Set<TranslationProviderID>
        var switchTargets: [TranslationProviderID]
        var onToggleCollapse: (TranslationProviderID) -> Void
        var onSwitch: (TranslationProviderID, TranslationProviderID) -> Void
        var onAddAll: () -> Void
        /// AI is shown by its concrete model name in the switch menu.
        var displayName: (TranslationProviderID) -> String = { $0.displayName }
    }

    /// A provider that has failed this many times in a row stops rendering
    /// its full error and collapses to one line with a Disable button.
    static let collapseAfterFailures = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(mergedRows, id: \.id) { row in
                APISegmentRow(
                    title: row.title,
                    segment: row.segment,
                    isSnapshot: isSnapshot,
                    controls: controls,
                    collapsed: controls?.collapsedIDs.contains(row.segment.id) ?? false,
                    onDisable: onDisable
                )
            }
        }
    }

    private struct Row {
        var id: String
        var title: String
        var segment: ProviderSegment
    }

    /// Providers that returned the same text collapse into one row titled
    /// "Google · Microsoft" — two identical lines told the user nothing and
    /// cost a row of tooltip height. Only successes merge; pending and
    /// failed segments always keep their own row. The live tooltip disables
    /// this because each provider row needs its own controls.
    private var mergedRows: [Row] {
        var rows: [Row] = []
        var rowIndexByResult: [String: Int] = [:]
        for segment in segments {
            if mergeIdenticalResults,
               case .success(let output, _, _, _) = segment.state {
                let key = output.result.trimmingCharacters(in: .whitespacesAndNewlines)
                if let index = rowIndexByResult[key] {
                    rows[index].title += " · " + segment.displayName
                    rows[index].id += "+" + segment.id.rawValue
                    continue
                }
                rowIndexByResult[key] = rows.count
            }
            rows.append(Row(id: segment.id.rawValue, title: segment.displayName, segment: segment))
        }
        return rows
    }
}

private struct APISegmentRow: View {
    let title: String
    let segment: ProviderSegment
    let isSnapshot: Bool
    let controls: APISegmentsBlock.Controls?
    let collapsed: Bool
    let onDisable: ((TranslationProviderID) -> Void)?

    @State private var hovering = false

    var body: some View {
        // Provider name sits as its own header row with a hairline rule, so
        // several providers stack as scannable sections instead of one run
        // of text. The translation row owns the trailing copy button, which
        // stays hidden until the pointer is over this provider's block.
        VStack(alignment: .leading, spacing: 5) {
            header
            if !collapsed {
                content
            }
        }
        .onHover { hovering = $0 }
    }

    private var header: some View {
        SegmentHeader(
            title: title,
            controls: controls.map { block in
                SegmentHeaderControls(
                    collapsed: collapsed,
                    switchTargets: block.switchTargets,
                    onToggleCollapse: { block.onToggleCollapse(segment.id) },
                    onSwitch: { target in block.onSwitch(segment.id, target) },
                    onAddAll: block.onAddAll,
                    displayName: block.displayName
                )
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch segment.state {
        case .loading:
            pendingRow
        case .streaming(_, let output):
            if output.result.isEmpty {
                pendingRow
            } else {
                successRows(output)
            }
        case .success(let output, _, _, _):
            successRows(output)
        case .failure(let error):
            if segment.consecutiveFailures >= APISegmentsBlock.collapseAfterFailures {
                collapsedFailureRow(error)
            } else {
                HStack(alignment: .top, spacing: 7) {
                    Text(error.title)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.red.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(error.message ?? error.title)
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.8))
                        .frame(width: 20, height: 20)
                }
            }
        }
    }

    /// One quiet line instead of a red error on every translation once a
    /// provider is clearly down (blocked network, dead endpoint). The last
    /// error stays reachable via the tooltip.
    private func collapsedFailureRow(_ error: DisplayError) -> some View {
        HStack(spacing: 7) {
            Text(L.pick(
                "Failed \(segment.consecutiveFailures) times in a row",
                "连续失败 \(segment.consecutiveFailures) 次"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help(error.message ?? error.title)
            Spacer(minLength: 4)
            if let onDisable {
                Button(L.pick("Disable", "停用")) { onDisable(segment.id) }
                    .controlSize(.mini)
                    .help(L.pick("Turn this provider off in settings", "在设置中关闭这个翻译源"))
            }
        }
    }

    @ViewBuilder
    private var pendingRow: some View {
        if isSnapshot {
            Text(L.pick("(no result)", "（无结果）"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        } else {
            HStack {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(height: 14)
                Spacer()
            }
        }
    }

    /// Render successful output as one or more rows. Current built-in
    /// providers (Google, Microsoft) always return a single string per
    /// request, but the multi-row path is here for any future provider
    /// that might return several meanings — that case should look identical
    /// to the AI multi-meaning section.
    @ViewBuilder
    private func successRows(_ output: TranslationOutput) -> some View {
        let items = output.items.isEmpty ? [output.result] : output.items
        if items.count <= 1 {
            translationRow(text: items[0], showBullet: false)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    translationRow(text: item, showBullet: true)
                }
            }
        }
    }

    private func translationRow(text: String, showBullet: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            if showBullet {
                Text("•")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: text, isVisible: hovering)
        }
    }
}
