import AppKit
import SwiftUI

// MARK: - Copy button

/// Copy-to-pasteboard icon button with a 1.2s "copied" checkmark. Owns
/// its own feedback state so every row that needs one doesn't re-implement
/// the timer.
struct CopyButton: View {
    let text: String
    var tooltip: String = L.pick("Copy this", "复制这一条")

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
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .resizable()
                .scaledToFit()
                .frame(width: 10, height: 10)
                .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
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
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
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
                        Image(systemName: controls.collapsed ? "chevron.right" : "chevron.down")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 10, height: 10)
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
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
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let image = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = .tertiaryLabelColor
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
        VStack(alignment: .leading, spacing: 4) {
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

    var body: some View {
        // Provider name sits as a small label *above* the translation row(s).
        // The translation row owns the trailing copy button so the icon
        // aligns with the text it copies — not with the label up top.
        VStack(alignment: .leading, spacing: 2) {
            header
            if !collapsed {
                content
            }
        }
        .padding(.vertical, 2)
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
            VStack(alignment: .leading, spacing: 2) {
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
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: text)
        }
    }
}
