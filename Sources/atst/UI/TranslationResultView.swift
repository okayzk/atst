import AppKit
import SwiftUI

/// Tooltip body — renders either:
///   - the two-segment text layout (API rows on top, AI section below),
///   - the screenshot result (single AI block, like before),
///   - the global failure / idle / empty-state messages.
///
/// All sizing flows from `readSize` upward into `FloatingPanelController`,
/// which mirrors the SwiftUI fitting height into the NSPanel frame.
struct TranslationResultView: View {
    @ObservedObject var viewModel: TranslatorViewModel
    /// Drives the maximum content height. Owned and updated by
    /// `FloatingPanelController` so the tooltip can never overflow the
    /// current screen, and so dragging to a position with more room
    /// dismisses the scroll bar automatically.
    @ObservedObject var layout: TooltipLayout
    var onClose: () -> Void
    var onContentSizeChange: (CGSize) -> Void = { _ in }
    /// Invoked when the user taps the "cached" indicator (header refresh).
    /// Receives the source text that should be re-translated.
    var onRefresh: (String) -> Void = { _ in }
    /// Invoked when the user clicks the empty-state "Open settings" CTA.
    /// Wired up by the panel controller so a tooltip-driven settings open
    /// can dismiss the tooltip first.
    var onOpenSettings: () -> Void = {}
    /// Invoked with the typed text when the user submits the manual-entry
    /// editor (Return or the Translate button).
    var onSubmitInput: (String) -> Void = { _ in }
    /// Invoked when the user clicks the source block of a finished manual
    /// translation, to reopen the editor with the original text.
    var onEditSource: (String, TextSegments) -> Void = { _, _ in }
    /// Pinned-note mode swaps the pin action for unpin and draws the accent
    /// border so a sticky note stays visually distinct from the live
    /// tooltip.
    var isPinnedNote: Bool = false
    var onUnpin: (() -> Void)? = nil
    var surfaceBorder: AdaptiveGlassSurface.Border = .subtle

    @State private var descriptionExpanded: Bool = false
    @State private var lastSeenSourceForExpansion: String = ""
    /// Provider rows the user has temporarily hidden. Purely a view state:
    /// collapsing never cancels a request or triggers a new one.
    @State private var collapsedProviders: Set<TranslationProviderID> = []
    @State private var lastSeenTranslationGeneration: Int = 0
    @FocusState private var inputFocused: Bool

    private let cornerRadius: CGFloat = 10

    /// Insets applied to the tooltip's inner VStack — same values are
    /// negated and re-applied to the header's drag handle so it can
    /// bleed edge-to-edge for a larger hit area without changing the
    /// visual layout. Keep these in sync by referring to the constants
    /// rather than retyping the numbers.
    private enum ContentInset {
        static let horizontal: CGFloat = 11
        static let top: CGFloat = 8
        static let bottom: CGFloat = 7
    }

    /// How far the drag handle extends below the header's visual frame.
    /// Bleeds into the VStack's `headerToContentSpacing` (6pt) plus a
    /// small overlap into the first content row's top — a deliberate
    /// design choice for a fatter hit target, not a coupling with any
    /// specific layout constant.
    private let dragHandleBottomBleed: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topLeading) {
            tooltipChrome(descriptionExpanded: descriptionExpanded, includeSurface: true)

            if hasRenderableDescription {
                tooltipChrome(descriptionExpanded: true, includeSurface: false)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // Keep the window sized to the expanded content while only the visible
        // SwiftUI chrome changes height. That removes the janky cross-process
        // feedback loop where an NSPanel resize tries to follow every frame of
        // the disclosure animation.
        .fixedSize(horizontal: false, vertical: true)
        .readSize(onContentSizeChange)
        .onReceive(viewModel.$state) { state in
            syncExpansion(for: state)
        }
        .onReceive(viewModel.$translationGeneration) { generation in
            guard generation != lastSeenTranslationGeneration else { return }
            lastSeenTranslationGeneration = generation
            collapsedProviders.removeAll()
        }
    }

    private func tooltipChrome(descriptionExpanded expanded: Bool, includeSurface: Bool) -> some View {
        let stack = tooltipStack(descriptionExpanded: expanded)
        return Group {
            if includeSurface {
                stack.modifier(AdaptiveGlassSurface(cornerRadius: cornerRadius, border: surfaceBorder))
            } else {
                stack
            }
        }
        .padding(5)
    }

    private func tooltipStack(descriptionExpanded expanded: Bool) -> some View {
        // Wrap the stack in a ScrollView whose height tops out at
        // `layout.maxContentHeight`. SwiftUI sizes the ScrollView to its
        // content's natural height when content fits, only engaging the
        // scroll bar (and capping height) when natural > max. The view
        // therefore stays scroll-free for short translations and only
        // shows a scroll bar when the panel literally can't fit the
        // content within the available screen space.
        //
        // The inner `header` is the drag handle (see WindowDragHandle in
        // tooltipHeader) — keeping it inside the scroll area means the
        // user can grab it from the top edge even when content scrolls,
        // matching native macOS behaviour (toolbar pinned at top).
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                header
                content(descriptionExpanded: expanded)
            }
            .padding(.horizontal, ContentInset.horizontal)
            .padding(.top, ContentInset.top)
            .padding(.bottom, ContentInset.bottom)
            .frame(width: preferredTooltipWidth, alignment: .leading)
        }
        .frame(maxHeight: layout.maxContentHeight)
        .fixedSize(horizontal: true, vertical: true)
    }

    /// Two-tier tooltip width — see `TooltipSizing` for the rule and why.
    /// Pinned notes reuse this view, so a wide live tooltip remains wide
    /// once pinned.
    /// In input mode the width follows the typed text with the same rule,
    /// so the panel doesn't jump when the result replaces the editor.
    private var preferredTooltipWidth: CGFloat {
        if case .input = viewModel.state {
            return TooltipSizing.preferredWidth(forSource: viewModel.inputDraft)
        }
        return TooltipSizing.preferredWidth(
            forSource: viewModel.state.sourceText,
            hasDictionary: hasDictionarySegment
        )
    }

    /// True while a dictionary card is loading or showing. Loading counts
    /// too: the panel must not resize when the lookup lands.
    private var hasDictionarySegment: Bool {
        guard case .text(let segments) = viewModel.state,
              let dictionary = segments.dictionary else { return false }
        switch dictionary.state {
        case .loading, .success:
            return true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(headerTitle)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            // Header-level refresh: only visible when at least one segment
            // was served from cache. Re-translates from scratch and bypasses
            // the cache for every segment.
            if anyFromCache {
                headerIconButton(
                    "arrow.clockwise",
                    help: L.pick("Refresh (bypass cache)", "重新翻译（绕过缓存）")
                ) {
                    onRefresh(viewModel.state.sourceText)
                }
            }

            if isPinnedNote {
                if let onUnpin {
                    headerIconButton(
                        "pin.slash",
                        help: L.pick("Unpin (return to tooltip)", "取消置顶（回到翻译浮窗）")
                    ) {
                        onUnpin()
                    }
                }
            } else if canPin {
                headerIconButton(
                    "pin",
                    help: L.pick("Pin as note", "固定为便签"),
                    rotation: -30
                ) {
                    viewModel.pinned = true
                }
            }

            headerIconButton(
                "gearshape",
                help: L.pick("Settings", "设置")
            ) {
                onOpenSettings()
            }

            headerIconButton("xmark", help: L.pick("Close", "关闭")) {
                onClose()
            }
        }
        // The whole header strip — model name, status dot, spacer — is a
        // drag handle for the floating panel. Buttons inside (refresh /
        // pin / close) keep their own click handling because they sit
        // *above* the background drag-initiator. Cursor turns into an
        // open hand on hover so users discover the affordance.
        //
        // Negative padding on the background lets the drag handle's
        // AppKit view occupy a hit area BIGGER than the header's visual
        // frame, without changing the header's own layout. The bleed
        // values mirror the tooltip's own insets so the drag handle
        // stretches edge-to-edge of the visible tooltip surface; the
        // bottom bleed pushes into the VStack spacing for a fatter
        // grab target. Content children have their own hit handling
        // and sit ABOVE this background, so the extra hit area never
        // steals clicks.
        .background(
            WindowDragHandle()
                .padding(.top, -ContentInset.top)
                .padding(.bottom, -dragHandleBottomBleed)
                .padding(.horizontal, -ContentInset.horizontal)
        )
    }

    private var headerTitle: String {
        switch viewModel.state {
        case .screenshotLoading(_, let model, _),
             .screenshotStreaming(_, _, let model, _),
             .screenshotSuccess(_, _, let model):
            return model.isEmpty ? Branding.appName : model
        case .text(let segments):
            return segments.languagePairLabel ?? Branding.appName
        case .input:
            if viewModel.inputPrevious != nil {
                return L.pick("Edit original", "编辑原文")
            }
            return L.pick("Type to translate", "输入翻译")
        case .idle, .failure:
            return Branding.appName
        }
    }

    /// One geometry for every header icon: a 10×10 glyph inside a 16×16 hit
    /// area, shared tint. Keeps refresh / pin / unpin / close identical to
    /// the switch / collapse / copy controls on each result row.
    private func headerIconButton(
        _ systemName: String,
        help: String,
        rotation: Double = 0,
        action: @escaping () -> Void
    ) -> some View {
        ResultIconButton(
            systemName: systemName,
            help: help,
            rotation: rotation,
            action: action
        )
    }

    private var canPin: Bool {
        switch viewModel.state {
        case .text(let segments):
            return segments.hasAnyContent
        case .screenshotStreaming(_, let output, _, _):
            return !output.result.isEmpty
        case .screenshotSuccess:
            return true
        case .idle, .input, .screenshotLoading, .failure:
            return false
        }
    }

    private var anyFromCache: Bool {
        if case .text(let segments) = viewModel.state {
            return segments.allSegments.contains { segment in
                if case .success(_, _, true, _) = segment.state { return true }
                return false
            }
        }
        return false
    }

    // MARK: - Body content

    @ViewBuilder
    private func content(descriptionExpanded expanded: Bool) -> some View {
        switch viewModel.state {
        case .idle:
            placeholder(L.pick(
                "Select text, then press the translate hotkey",
                "选中文字，按下翻译快捷键"
            ))
        case .input:
            VStack(alignment: .leading, spacing: 8) {
                inputBox
                if let previous = viewModel.inputPrevious, previous.hasAnyContent {
                    Divider().padding(.vertical, 1)
                    previousTranslation(previous, descriptionExpanded: expanded)
                }
            }
        case .text(let segments):
            textContent(segments, descriptionExpanded: expanded)
        case .screenshotLoading(let message, _, _):
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .screenshotStreaming(_, let output, _, _):
            translationItems(output, isStreaming: true)
        case .screenshotSuccess(let output, _, _):
            translationItems(output, isStreaming: false)
        case .failure(let error):
            failureBlock(error)
        }
    }

    @ViewBuilder
    private func textContent(
        _ segments: TextSegments,
        descriptionExpanded expanded: Bool,
        interactive: Bool = true
    ) -> some View {
        let usedIDs = Set(segments.allSegments.map(\.id))
        let switchTargets = interactive
            ? viewModel.configuration.availableProviderKinds.filter { !usedIDs.contains($0) }
            : []
        let providerDisplayName: (TranslationProviderID) -> String = { id in
            if id == .ai {
                let model = viewModel.configuration.textModel
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return model.isEmpty ? "AI" : model
            }
            return id.displayName
        }
        let controls = interactive
            ? APISegmentsBlock.Controls(
                collapsedIDs: collapsedProviders,
                switchTargets: switchTargets,
                onToggleCollapse: { id in toggleCollapse(id) },
                onSwitch: { oldID, newID in
                    collapsedProviders.remove(oldID)
                    collapsedProviders.remove(newID)
                    viewModel.switchProvider(from: oldID, to: newID)
                },
                onAddAll: { addAllServices(usedIDs: usedIDs) },
                displayName: providerDisplayName
            )
            : nil

        let dictionaryEntry: DictionaryEntry? = {
            if let dictionary = segments.dictionary, case .success(let entry) = dictionary.state {
                return entry
            }
            return nil
        }()

        VStack(alignment: .leading, spacing: 8) {
            if segments.sourceEditable {
                sourceBlock(segments)
            }
            if let dictionary = segments.dictionary, case .loading = dictionary.state {
                dictionaryLoadingRow
            }
            if let dictionaryEntry {
                // The card no longer carries its own surface, so it needs a
                // little more air before the provider rows below it.
                DictionaryCard(entry: dictionaryEntry)
                    .padding(.bottom, 6)
            }
            if segments.bothDisabled {
                if dictionaryEntry == nil {
                    emptyState
                }
            } else if viewModel.configuration.aiResultFirst {
                aiBlock(
                    segments,
                    descriptionExpanded: expanded,
                    switchTargets: switchTargets,
                    providerDisplayName: providerDisplayName,
                    usedIDs: usedIDs,
                    interactive: interactive
                )
                if !segments.api.isEmpty {
                    apiBlock(segments, controls: controls, interactive: interactive)
                        .padding(.top, 6)
                }
            } else {
                apiBlock(segments, controls: controls, interactive: interactive)
                if segments.ai != nil {
                    aiBlock(
                        segments,
                        descriptionExpanded: expanded,
                        switchTargets: switchTargets,
                        providerDisplayName: providerDisplayName,
                        usedIDs: usedIDs,
                        interactive: interactive
                    )
                    .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func apiBlock(
        _ segments: TextSegments,
        controls: APISegmentsBlock.Controls?,
        interactive: Bool
    ) -> some View {
        if !segments.api.isEmpty {
            APISegmentsBlock(
                segments: segments.api,
                controls: controls,
                mergeIdenticalResults: !interactive
            ) { id in
                viewModel.disableAPIProvider(id)
            }
        }
    }

    @ViewBuilder
    private func aiBlock(
        _ segments: TextSegments,
        descriptionExpanded expanded: Bool,
        switchTargets: [TranslationProviderID],
        providerDisplayName: @escaping (TranslationProviderID) -> String,
        usedIDs: Set<TranslationProviderID>,
        interactive: Bool
    ) -> some View {
        if let ai = segments.ai {
            AISegmentBlock(
                segment: ai,
                descriptionExpanded: expanded,
                toggleExpand: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.04)) {
                        descriptionExpanded.toggle()
                    }
                },
                phoneticEnabled: viewModel.configuration.phoneticEnabled,
                smartExplanationEnabled: viewModel.configuration.smartExplanationEnabled,
                sourceText: segments.source,
                headerControls: interactive
                    ? SegmentHeaderControls(
                        collapsed: collapsedProviders.contains(.ai),
                        switchTargets: switchTargets,
                        onToggleCollapse: { toggleCollapse(.ai) },
                        onSwitch: { newID in
                            collapsedProviders.remove(.ai)
                            collapsedProviders.remove(newID)
                            viewModel.switchProvider(from: .ai, to: newID)
                        },
                        onAddAll: { addAllServices(usedIDs: usedIDs) },
                        displayName: providerDisplayName
                    )
                    : nil
            )
        }
    }

    /// Compact placeholder shown while a dictionary lookup is in flight.
    /// In dictionary-first mode it is the only content until the lookup
    /// resolves; in parallel mode it sits above the provider rows. It has
    /// no card surface of its own — the finished card doesn't either, so
    /// the row must not flash a rounded block before the entry lands.
    private var dictionaryLoadingRow: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(height: 14)
            Text(L.pick("Looking up dictionary…", "查词典…"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
        }
    }

    /// The previous result rendered under the editor. The source block is
    /// stripped — the editor above already shows that text — and the
    /// per-result controls are disabled because the live state is `.input`.
    private func previousTranslation(_ segments: TextSegments, descriptionExpanded expanded: Bool) -> some View {
        textContent(segments.withoutSourceEditing, descriptionExpanded: expanded, interactive: false)
    }

    private func toggleCollapse(_ id: TranslationProviderID) {
        if collapsedProviders.contains(id) {
            collapsedProviders.remove(id)
        } else {
            collapsedProviders.insert(id)
        }
    }

    /// "Call all other enabled services" under the switch menu's divider.
    /// Existing rows stay put; every enabled provider not already on screen
    /// is added and translated. New rows start expanded.
    private func addAllServices(usedIDs: Set<TranslationProviderID>) {
        let unused = viewModel.configuration.availableProviderKinds.filter { !usedIDs.contains($0) }
        collapsedProviders.subtract(unused)
        viewModel.addAllAvailableProviders()
    }

    /// Read-only original text shown above the result of a manual
    /// translation. Clicking anywhere in the block reopens the editor with
    /// this text; the pencil is the discoverable affordance.
    private func sourceBlock(_ segments: TextSegments) -> some View {
        Button {
            onEditSource(segments.source, segments)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.pick("Original", "原文"))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Text(segments.source)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L.pick("Edit the original text", "编辑原文"))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "switch.2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.pick(
                        "No translator enabled",
                        "未启用任何翻译方式"
                    ))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    Text(L.pick(
                        "Enable AI or API translation in settings to start translating.",
                        "请在设置中启用 AI 翻译或 API 翻译后再使用。"
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                onOpenSettings()
            } label: {
                Text(L.pick("Open Settings", "打开设置"))
                    .font(.system(size: 12, weight: .medium))
            }
            .controlSize(.small)
        }
    }

    // MARK: - Manual entry

    private var inputBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $viewModel.inputDraft)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($inputFocused)
                .frame(minHeight: 56, maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(alignment: .topLeading) {
                    if viewModel.inputDraft.isEmpty {
                        Text(L.pick("Type or paste text to translate…", "输入或粘贴要翻译的文本…"))
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 11)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
                // Return submits; Shift+Return inserts a newline for
                // multi-paragraph input.
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    submitInput()
                    return .handled
                }
            HStack {
                Text(viewModel.inputPrevious == nil
                     ? L.pick("Return to translate · Shift+Return for a new line", "回车翻译 · Shift+回车换行")
                     : L.pick("Return to re-translate · Shift+Return for a new line", "回车重新翻译 · Shift+回车换行"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L.pick("Translate", "翻译")) { submitInput() }
                    .controlSize(.small)
                    .disabled(viewModel.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            // Focus lands only once the panel is key; defer a turn so the
            // window has finished ordering front.
            DispatchQueue.main.async { inputFocused = true }
        }
    }

    private func submitInput() {
        let text = viewModel.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.inputDraft = ""
        onSubmitInput(text)
    }

    private func failureBlock(_ error: DisplayError) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(error.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                if let message = error.message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Screenshot translation rendering

    @ViewBuilder
    private func translationItems(_ output: TranslationOutput, isStreaming: Bool) -> some View {
        let items = output.items
        if items.isEmpty {
            placeholderText(isStreaming ? L.pick("Translating…", "翻译中…") : "")
        } else if items.count == 1 {
            singleMeaningRow(items[0], isStreaming: isStreaming)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    multiMeaningRow(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func singleMeaningRow(_ text: String, isStreaming: Bool) -> some View {
        let isPlaceholder = text.isEmpty && isStreaming
        let displayText = isPlaceholder ? L.pick("Translating…", "翻译中…") : text
        return HStack(alignment: .top, spacing: 7) {
            Text(displayText)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isPlaceholder {
                CopyButton(text: text, tooltip: L.pick("Copy translation", "复制译文"))
            }
        }
    }

    private func multiMeaningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("•")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: text)
        }
        .padding(.vertical, 1)
    }

    private func placeholderText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Auto-expand bookkeeping

    private var currentOutput: TranslationOutput {
        viewModel.state.currentOutput
    }

    /// Only the AI segment surfaces phonetic/description — and only when
    /// the user has enabled the corresponding toggles.
    private var hasRenderableDescription: Bool {
        guard viewModel.configuration.smartExplanationEnabled else { return false }
        guard let description = aiSegmentDescription, !description.isEmpty else { return false }
        return true
    }

    private var aiSegmentDescription: String? {
        guard case .text(let segments) = viewModel.state, let ai = segments.ai else { return nil }
        return ai.state.output.description
    }

    private func syncExpansion(for state: TranslationState) {
        let source = state.sourceText
        guard !source.isEmpty else { return }

        if source != lastSeenSourceForExpansion {
            lastSeenSourceForExpansion = source
            descriptionExpanded = viewModel.configuration.smartExplanationExpandedByDefault
        }

        // Auto-expand description when the AI segment lands with
        // untranslatable=true and there's a description with the user's
        // reason in it — same behaviour as before, scoped to the AI segment.
        if case .text(let segments) = state,
           let ai = segments.ai,
           case .success(let output, _, _, _) = ai.state,
           output.untranslatable,
           viewModel.configuration.smartExplanationEnabled,
           output.hasDescription,
           !descriptionExpanded {
            descriptionExpanded = true
        }
    }
}

// MARK: - AI segment block

private struct AISegmentBlock: View {
    let segment: ProviderSegment
    let descriptionExpanded: Bool
    let toggleExpand: () -> Void
    let phoneticEnabled: Bool
    let smartExplanationEnabled: Bool
    let sourceText: String
    var headerControls: SegmentHeaderControls? = nil

    private let speaker = TooltipSpeaker()
    @State private var hovering = false

    var body: some View {
        // 5pt keeps the service header and its translation reading as one
        // block while still leaving the rule room to breathe.
        VStack(alignment: .leading, spacing: 5) {
            SegmentHeader(
                title: segment.modelHint ?? segment.displayName,
                controls: headerControls
            )
            if headerControls?.collapsed != true {
                content
                footer
                if let description = segment.state.output.description,
                   !description.isEmpty,
                   smartExplanationEnabled {
                    CollapsibleSection(
                        isExpanded: descriptionExpanded,
                        animation: .spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.04)
                    ) {
                        TooltipDescription(markdown: description)
                    }
                }
            }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var content: some View {
        switch segment.state {
        case .loading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 2)
        case .streaming(_, let output):
            translationItems(output, isStreaming: true)
        case .success(let output, _, _, _):
            translationItems(output, isStreaming: false)
        case .failure(let error):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let message = error.message {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func translationItems(_ output: TranslationOutput, isStreaming: Bool) -> some View {
        let items = output.items
        if items.isEmpty {
            if isStreaming {
                HStack {
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 2)
            } else {
                placeholderText("")
            }
        } else if items.count == 1 {
            singleMeaningRow(items[0], isStreaming: isStreaming)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    multiMeaningRow(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func singleMeaningRow(_ text: String, isStreaming: Bool) -> some View {
        let isPlaceholder = text.isEmpty && isStreaming
        return HStack(alignment: .top, spacing: 7) {
            if isPlaceholder {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(text)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(text: text, tooltip: L.pick("Copy translation", "复制译文"), isVisible: hovering)
            }
        }
    }

    private func multiMeaningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("•")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: text, isVisible: hovering)
        }
        .padding(.vertical, 1)
    }

    private func placeholderText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if phoneticEnabled, let phonetic = segment.state.output.phonetic, !phonetic.isEmpty {
                Button {
                    speaker.speak(sourceText)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(phonetic)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderless)
                .help(L.pick("Play / \(phonetic)", "朗读 / \(phonetic)"))
            }

            Spacer(minLength: 4)

            if smartExplanationEnabled, segment.state.output.hasDescription {
                Button(action: toggleExpand) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 14)
                        .contentShape(Rectangle())
                        .rotationEffect(.degrees(descriptionExpanded ? 180 : 0))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help(descriptionExpanded
                      ? L.pick("Collapse explanation", "收起释义")
                      : L.pick("Expand explanation", "展开释义"))
            }
        }
    }
}
