import AppKit
import Carbon
import ServiceManagement
import SwiftUI

private enum ShortcutTarget: Equatable {
    case text
    case screenshot
}

/// Root ("General") settings page: permissions, common options, translator
/// entry rows, hotkeys, screenshot OCR, cache and stats. Owns the hotkey
/// recording and permission-polling state so the shell stays a thin router.
struct SettingsGeneralPage: View {
    @Binding var draft: AppConfiguration
    @ObservedObject var cache: TranslationCache
    @ObservedObject var stats: TranslationStats
    var save: () -> Void
    var debouncedSave: () -> Void
    var openAIPage: () -> Void
    var openAPIPage: () -> Void
    var openDictionaryPage: () -> Void

    @State private var accessibilityTrusted = PermissionChecker.isAccessibilityTrusted
    @State private var screenRecordingTrusted = PermissionChecker.isScreenRecordingTrusted
    /// `IsSecureEventInputEnabled()` — when another app puts the system
    /// into Secure Keyboard Entry mode, our hotkeys silently break even
    /// though all three TCC perms are granted. Polling this lets the
    /// settings UI surface a warning so the user knows where to look.
    @State private var secureInputActive = IsSecureEventInputEnabled()
    @State private var recordingTarget: ShortcutTarget?
    @State private var shortcutMonitor: Any?
    @State private var permissionPollTask: Task<Void, Never>?

    var body: some View {
        SettingsPage(maxHeight: 540) {
            languageSection
            translatorNavSection
            serviceSection
            hotkeysSection
            generalSection
            advancedSection
            permissionsSection
        }
        .onAppear {
            refreshPermissionStatus()
            startPermissionPolling()
        }
        .onDisappear {
            stopRecordingShortcut()
            permissionPollTask?.cancel()
            permissionPollTask = nil
        }
    }

    // MARK: - Language section

    private var languageSection: some View {
        SettingsSection(title: L.pick("Language", "语言")) {
            targetLanguageRow
            SettingsRowDivider()
            secondaryTargetLanguageRow
        }
    }

    // MARK: - Advanced section

    private var advancedSection: some View {
        SettingsAdvancedSection(title: L.pick("Advanced", "高级")) {
            advancedGroupTitle(L.pick("Screenshot", "截图"))
            SettingsToggleRow(
                title: L.pick("Use Vision OCR", "使用 Vision OCR"),
                isOn: $draft.screenshotUseVisionOCR,
                onChange: save
            )
            SettingsRowDivider()
            ocrLanguagesRow
                .opacity(draft.screenshotUseVisionOCR ? 1 : SettingsStyle.disabledOpacity)
                .disabled(!draft.screenshotUseVisionOCR)

            advancedGroupTitle(L.pick("Cache", "缓存"))
            SettingsToggleRow(
                title: L.pick("Enable cache", "开启缓存"),
                isOn: $draft.cacheEnabled,
                onChange: save
            )
            SettingsRowDivider()
            cacheNumberRow(
                title: L.pick("Days to keep", "保留天数"),
                subtitle: "",
                value: $draft.cacheTTLDays,
                range: 1...365
            )
            .opacity(draft.cacheEnabled ? 1 : SettingsStyle.disabledOpacity)
            .disabled(!draft.cacheEnabled)
            SettingsRowDivider()
            cacheNumberRow(
                title: L.pick("Max entries", "缓存上限"),
                subtitle: "",
                value: $draft.cacheMaxEntries,
                range: 100...50000
            )
            .opacity(draft.cacheEnabled ? 1 : SettingsStyle.disabledOpacity)
            .disabled(!draft.cacheEnabled)

            advancedGroupTitle(L.pick("Stats", "统计"))
            SettingsStatsSection(cache: cache, stats: stats, embedded: true)
        }
    }

    private func advancedGroupTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    /// Recognition-language picker. Selected languages render as removable
    /// chips inline; a trailing "+" button opens a menu with whatever
    /// languages aren't yet selected. Tap order = recognition priority,
    /// so the chip list doubles as a priority list.
    private var ocrLanguagesRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L.pick("Recognition languages", "识别语言"))
                        .font(SettingsStyle.rowTitleFont)
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 4)
            }
            languageChipsRow
        }
        .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
    }

    private var languageChipsRow: some View {
        FlowLayoutWrapping(spacing: 4, runSpacing: 4) {
            ForEach(draft.ocrLanguages, id: \.self) { code in
                LanguageChip(
                    name: displayName(for: code),
                    onRemove: draft.ocrLanguages.count > 1
                        ? { removeOCRLanguage(code) }
                        : nil  // refuse to remove the last one
                )
            }
            addLanguageMenu
        }
    }

    private var addLanguageMenu: some View {
        let unselected = VisionOCRService.supportedLanguages
            .filter { !draft.ocrLanguages.contains($0.code) }
        return Menu {
            if unselected.isEmpty {
                Text(L.pick("All supported languages added", "已添加所有支持的语言"))
            } else {
                ForEach(unselected) { language in
                    Button(language.displayName) {
                        draft.ocrLanguages.append(language.code)
                        save()
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text(L.pick("Add", "添加"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(unselected.isEmpty)
        .opacity(unselected.isEmpty ? 0.4 : 1)
    }

    private func displayName(for code: String) -> String {
        VisionOCRService.supportedLanguages.first(where: { $0.code == code })?.displayName ?? code
    }

    private func removeOCRLanguage(_ code: String) {
        draft.ocrLanguages.removeAll { $0 == code }
        if draft.ocrLanguages.isEmpty {
            // Should be unreachable thanks to the chip's onRemove gate, but
            // belt-and-braces: never let the user end up with zero
            // recognition languages because Vision wouldn't recognise
            // anything at all.
            draft.ocrLanguages = AppConfiguration.defaultOCRLanguages
        }
        save()
    }

    /// AI/API entry rows shown on the General page. Each row carries its
    /// enable toggle inline (so the user can flip a segment on/off without
    /// drilling in) plus a chevron to push the detail subpage.
    ///
    /// Order matches the live tooltip layout — API rows render above the
    /// AI section there, so we mirror that order here. Cheap visual
    /// continuity between settings and runtime.
    private var translatorNavSection: some View {
        SettingsSection(title: L.pick("Translators", "翻译方式")) {
            translatorNavRow(
                title: L.pick("API Translation", "API 翻译"),
                subtitle: apiSubtitle,
                isOn: $draft.apiEnabled,
                onTap: openAPIPage
            )
            SettingsRowDivider()
            translatorNavRow(
                title: L.pick("AI Translation", "AI 翻译"),
                subtitle: aiSubtitle,
                isOn: $draft.aiEnabled,
                onTap: openAIPage
            )
            SettingsRowDivider()
            translatorNavRow(
                title: L.pick("Dictionary", "查词"),
                subtitle: dictionarySubtitle,
                isOn: $draft.dictionaryEnabled,
                onTap: openDictionaryPage
            )
        }
    }

    private var dictionarySubtitle: String {
        if !draft.dictionaryEnabled {
            return L.pick("Off", "已关闭")
        }
        return L.pick("Youdao · macOS Dictionary", "有道 · 系统词典")
    }

    private var aiSubtitle: String {
        let trimmed = draft.textModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return L.pick("Model not configured", "尚未配置模型")
        }
        return trimmed
    }

    private var apiSubtitle: String {
        let enabled = draft.apiProviders.filter { entry in
            entry.enabled && (entry.kind?.isRuntimeAvailable ?? false)
        }.compactMap { entry -> String? in
            switch entry.kind {
            case .google: return "Google"
            case .microsoft: return "Microsoft"
            case .deepl: return "DeepL"
            case .system: return "Apple"
            case .ai, .none: return nil
            }
        }
        if enabled.isEmpty {
            return L.pick("No translators enabled", "未启用任何翻译源")
        }
        return enabled.joined(separator: " · ")
    }

    // MARK: - Translation services section

    /// The single place that controls which services run by default, the
    /// order their rows appear in, and whether the AI result sits above the
    /// API rows. Provider enablement still lives on the API subpage; this
    /// list only shows services that are currently available.
    private var serviceSection: some View {
        SettingsSection(title: L.pick("Translation services", "翻译服务")) {
            let available = draft.availableProviderKinds
            if available.isEmpty {
                Text(L.pick(
                    "Enable API or AI translation first.",
                    "请先启用 API 或 AI 翻译。"
                ))
                .font(SettingsStyle.rowSubtitleFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
                .padding(.vertical, SettingsStyle.rowVerticalPadding)
            } else {
                ForEach(Array(available.enumerated()), id: \.element) { index, kind in
                    serviceRow(kind: kind, available: available)
                    if index < available.count - 1 {
                        SettingsRowDivider()
                    }
                }
                SettingsRowDivider()
                SettingsToggleRow(
                    title: L.pick("Show AI result first", "AI 结果置顶"),
                    isOn: $draft.aiResultFirst,
                    onChange: save
                )
                .opacity(draft.aiEnabled ? 1 : SettingsStyle.disabledOpacity)
                .disabled(!draft.aiEnabled)
                if selectedDefaultServiceCount(available: available) == 0 {
                    Text(L.pick(
                        "Nothing selected — every enabled service will be used.",
                        "未选择默认服务时将调用所有已启用的服务。"
                    ))
                    .font(SettingsStyle.rowSubtitleFont)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
                    .padding(.vertical, SettingsStyle.rowVerticalPadding)
                }
            }
        }
    }

    private func selectedDefaultServiceCount(available: [TranslationProviderID]) -> Int {
        available.reduce(0) { count, kind in
            count + (draft.defaultProviderIDs.contains(kind.rawValue) ? 1 : 0)
        }
    }

    private func serviceRow(
        kind: TranslationProviderID,
        available: [TranslationProviderID]
    ) -> some View {
        let selected = draft.defaultProviderIDs.contains(kind.rawValue)
        let selectedCount = selectedDefaultServiceCount(available: available)
        let isLastSelected = selected && selectedCount == 1
        let subtitle = defaultServiceSubtitle(for: kind)

        return SettingsRow(
            title: kind.displayName,
            subtitle: subtitle.isEmpty ? nil : subtitle
        ) {
            HStack(spacing: 4) {
                if kind != .ai {
                    orderControls(for: kind)
                }
                Toggle("", isOn: Binding(
                    get: { draft.defaultProviderIDs.contains(kind.rawValue) },
                    set: { newValue in
                        guard !(isLastSelected && !newValue) else { return }
                        if newValue {
                            if !draft.defaultProviderIDs.contains(kind.rawValue) {
                                draft.defaultProviderIDs.append(kind.rawValue)
                            }
                        } else {
                            draft.defaultProviderIDs.removeAll { $0 == kind.rawValue }
                        }
                        save()
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(isLastSelected)
                .help(isLastSelected
                      ? L.pick("At least one service stays selected", "至少保留一个默认服务")
                      : "")
            }
        }
    }

    /// Reorders the enabled API providers. Disabled entries stay put, so the
    /// visible list moves exactly one step per tap.
    private func orderControls(for kind: TranslationProviderID) -> some View {
        let kinds = draft.enabledAPIProviderKinds
        let index = kinds.firstIndex(of: kind)
        let canMoveUp = (index ?? 0) > 0
        let canMoveDown = index.map { $0 < kinds.count - 1 } ?? false

        return HStack(spacing: 0) {
            Button {
                moveService(kind, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(!canMoveUp)
            .opacity(canMoveUp ? 1 : 0.3)
            .help(L.pick("Move up", "上移"))

            Button {
                moveService(kind, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(!canMoveDown)
            .opacity(canMoveDown ? 1 : 0.3)
            .help(L.pick("Move down", "下移"))
        }
    }

    private func moveService(_ kind: TranslationProviderID, offset: Int) {
        let kinds = draft.enabledAPIProviderKinds
        guard let index = kinds.firstIndex(of: kind) else { return }
        let target = index + offset
        guard kinds.indices.contains(target) else { return }
        let other = kinds[target]
        guard let a = draft.apiProviders.firstIndex(where: { $0.kind == kind }),
              let b = draft.apiProviders.firstIndex(where: { $0.kind == other }) else {
            return
        }
        draft.apiProviders.swapAt(a, b)
        save()
    }

    private func defaultServiceSubtitle(for kind: TranslationProviderID) -> String {
        switch kind {
        case .google, .microsoft, .deepl:
            return ""
        case .system:
            return kind.isRuntimeAvailable ? "" : L.pick("Requires macOS 26", "需 macOS 26")
        case .ai:
            let model = draft.textModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? L.pick("Model not configured", "尚未配置模型") : model
        }
    }

    private func translatorNavRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        onTap: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(SettingsStyle.rowTitleFont)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(SettingsStyle.rowSubtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .onChange(of: isOn.wrappedValue) { _ in save() }
            Button(action: onTap) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    // MARK: - Cache rows

    private func cacheNumberRow(
        title: String,
        subtitle: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(SettingsStyle.rowTitleFont)
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SettingsStyle.rowSubtitleFont)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.trailing)
                .frame(width: SettingsStyle.numberFieldWidth)
                .onChange(of: value.wrappedValue) { newValue in
                    let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                    if clamped != newValue { value.wrappedValue = clamped }
                    debouncedSave()
                }
        }
        .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
    }

    // MARK: - Other sections (Permissions / General / Hotkeys)

    private var permissionsSection: some View {
        SettingsAdvancedSection(
            title: L.pick("Permissions", "权限"),
            initiallyExpanded: !accessibilityTrusted || !screenRecordingTrusted || secureInputActive
        ) {
            VStack(spacing: 0) {
                if secureInputActive {
                    SettingsNotice(
                        text: L.pick(
                            "macOS Secure Keyboard Entry is active. Common culprits: 1Password autofill, Terminal, or a focused password field.",
                            "macOS 安全键盘输入被占用。常见来源：1Password 自动填充、Terminal、密码输入框。"
                        ),
                        title: L.pick(
                            "Hotkeys blocked by another app",
                            "快捷键被其他 App 拦截"
                        ),
                        style: .warning
                    )
                    .padding(8)
                    SettingsRowDivider()
                }
                SettingsPermissionRow(
                    title: L.pick("Selection translation", "划词翻译"),
                    requirement: L.pick("Accessibility", "辅助功能"),
                    granted: accessibilityTrusted,
                    openSettings: PermissionChecker.openAccessibilitySettings
                )
                SettingsRowDivider()
                SettingsPermissionRow(
                    title: L.pick("Screenshot translation", "截图翻译"),
                    requirement: L.pick("Screen recording", "屏幕录制"),
                    granted: screenRecordingTrusted,
                    openSettings: PermissionChecker.openScreenRecordingSettings
                )
            }
        }
    }

    private var generalSection: some View {
        SettingsSection(title: L.pick("General", "通用")) {
            // Every row shares the same horizontal layout — label (+
            // optional subtitle) on the left, control pinned to the right
            // edge — so the section has a consistent visual rhythm rather
            // than mixing "label above" and "label beside" patterns.
            uiLanguageRow
            SettingsRowDivider()
            appearanceRow
            SettingsRowDivider()
            launchAtLoginRow
            SettingsRowDivider()
            hideMenuBarIconRow
            SettingsRowDivider()
            pinnedNoteFollowsRow
        }
    }

    /// 170pt comfortably fits the longest preset label ("繁體中文") at
    /// .small picker size with breathing room. Kept in SettingsStyle so
    /// every page aligns to the same right edge.

    private var targetLanguageRow: some View {
        languagePickerRow(
            title: L.pick("Target Language", "目标语言"),
            subtitle: nil,
            selection: $draft.targetLanguage
        )
    }

    private var secondaryTargetLanguageRow: some View {
        languagePickerRow(
            title: L.pick("Secondary", "第二目标语言"),
            subtitle: nil,
            selection: $draft.secondaryTargetLanguage
        )
    }

    /// Native SwiftUI `Picker` so the chevron / hover background / focus
    /// ring come from AppKit. A saved free-form value not in the preset list
    /// is prepended above a divider so historical configs keep their
    /// selection visible.
    ///
    /// `.menu`-style Pickers don't stretch to fill `.frame(width:)` — the
    /// popup button hugs its longest option label — so the picker sits in a
    /// trailing-aligned fixed-width container to share the right edge with
    /// the segmented controls below.
    private func languagePickerRow(title: String, subtitle: String?, selection: Binding<String>) -> some View {
        let isCustom = !selection.wrappedValue.isEmpty
            && !TargetLanguagePreset.all.contains(selection.wrappedValue)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(SettingsStyle.rowTitleFont)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(SettingsStyle.rowSubtitleFont)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Picker("", selection: selection) {
                    if isCustom {
                        Text(selection.wrappedValue).tag(selection.wrappedValue)
                        Divider()
                    }
                    ForEach(TargetLanguagePreset.all, id: \.self) { preset in
                        Text(preset).tag(preset)
                    }
                }
                .labelsHidden()
                // .small (not .mini): the language is the most-changed value
                // in this section, so its text should read as clearly as
                // the row label next to it.
                .controlSize(.small)
                .fixedSize()
                .onChange(of: selection.wrappedValue) { _ in
                    save()
                }
            }
            .frame(width: SettingsStyle.controlWidth, alignment: .trailing)
        }
        .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
    }

    private var uiLanguageRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L.pick("Interface Language", "界面语言"))
                    .font(SettingsStyle.rowTitleFont)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 8)
            // Same right-aligned container as targetLanguageRow:
            // `.pickerStyle(.segmented).frame(width:)` doesn't force the
            // control to expand to the requested width — it hugs its
            // segment-content widths instead, so a row with longer
            // labels (e.g. "English") would render visibly wider than a
            // row with shorter labels (e.g. "浅色"). Wrapping in a
            // Spacer + fixed-width trailing container pins the right
            // edge of every General-section control to the same x.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Picker("", selection: $draft.uiLanguage) {
                    Text(L.pick("Auto", "自动")).tag(UILanguage.auto)
                    Text("English").tag(UILanguage.english)
                    Text("中文").tag(UILanguage.chinese)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .onChange(of: draft.uiLanguage) { _ in
                    save()
                }
            }
            .frame(width: SettingsStyle.controlWidth, alignment: .trailing)
        }
        .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
    }

    private var hotkeysSection: some View {
        SettingsSection(title: L.pick("Hotkeys", "快捷键")) {
            shortcutRow(L.pick("Selection translation", "划词翻译"), shortcut: $draft.textHotKey, target: .text)
            SettingsRowDivider()
            shortcutRow(L.pick("Screenshot translation", "截图翻译"), shortcut: $draft.screenshotHotKey, target: .screenshot)
        }
    }

    private var appearanceRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L.pick("Appearance", "外观"))
                    .font(SettingsStyle.rowTitleFont)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 8)
            // Same right-aligned container as uiLanguageRow — segmented
            // pickers hug their segment-content widths, so different
            // labels per row produce different physical widths unless
            // pinned to a trailing-aligned fixed-width parent.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Picker("", selection: $draft.appearanceMode) {
                    Text(L.pick("Auto", "自动")).tag(AppearanceMode.auto)
                    Text(L.pick("Light", "浅色")).tag(AppearanceMode.light)
                    Text(L.pick("Dark", "深色")).tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .onChange(of: draft.appearanceMode) { _ in
                    save()
                }
            }
            .frame(width: SettingsStyle.controlWidth, alignment: .trailing)
        }
        .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
    }

    private var pinnedNoteFollowsRow: some View {
        SettingsToggleRow(
            title: L.pick("Notes on all desktops", "便签跨桌面显示"),
            subtitle: L.pick(
                "Stay visible after switching desktop",
                "切换桌面后仍显示"
            ),
            isOn: $draft.pinnedNoteFollowsAcrossSpaces,
            onChange: save
        )
    }

    private var launchAtLoginRow: some View {
        SettingsToggleRow(
            title: L.pick("Launch at login", "登录时自动启动"),
            subtitle: launchAtLoginSubtitle,
            isOn: $draft.launchAtLogin,
            onChange: save
        )
    }

    private var hideMenuBarIconRow: some View {
        SettingsToggleRow(
            title: L.pick("Hide menu bar icon", "隐藏菜单栏图标"),
            isOn: $draft.hideMenuBarIcon,
            onChange: save
        )
    }

    /// After `register()` macOS may park the item in `.requiresApproval`
    /// and wait for the user to flip it on in Login Items themselves.
    private var launchAtLoginSubtitle: String {
        if draft.launchAtLogin, SMAppService.mainApp.status == .requiresApproval {
            return L.pick(
                "Approve in System Settings → Login Items",
                "请在系统设置 → 登录项中批准"
            )
        }
        return ""
    }

    // MARK: - Hotkey recording

    private func shortcutRow(
        _ title: String,
        shortcut: Binding<KeyboardShortcutConfig>,
        target: ShortcutTarget
    ) -> some View {
        let isRecording = recordingTarget == target
        return Button {
            if isRecording {
                stopRecordingShortcut()
            } else {
                beginRecordingShortcut(target)
            }
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(SettingsStyle.rowTitleFont)
                    .foregroundStyle(.primary)
                Spacer()
                Text(isRecording
                     ? L.pick("Press keys…", "按键…")
                     : shortcut.wrappedValue.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(isRecording ? Color.accentColor : .secondary)
                Image(systemName: isRecording ? "record.circle" : "pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isRecording ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
            .padding(.vertical, SettingsStyle.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func beginRecordingShortcut(_ target: ShortcutTarget) {
        recordingTarget = target
        stopShortcutMonitorOnly()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                self.recordingTarget = nil
                self.stopShortcutMonitorOnly()
                return nil
            }
            guard let recordingTarget = self.recordingTarget,
                  let shortcut = KeyboardShortcutConfig(event: event) else {
                return event
            }
            switch recordingTarget {
            case .text:
                draft.textHotKey = shortcut
            case .screenshot:
                draft.screenshotHotKey = shortcut
            }
            self.recordingTarget = nil
            self.stopShortcutMonitorOnly()
            save()
            return nil
        }
    }

    private func stopRecordingShortcut() {
        recordingTarget = nil
        stopShortcutMonitorOnly()
    }

    private func stopShortcutMonitorOnly() {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
    }

    // MARK: - Permission polling

    private func refreshPermissionStatus() {
        accessibilityTrusted = PermissionChecker.isAccessibilityTrusted
        screenRecordingTrusted = PermissionChecker.isScreenRecordingTrusted
        secureInputActive = IsSecureEventInputEnabled()
    }

    private func startPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                refreshPermissionStatus()
            }
        }
    }
}

/// Curated list of common translation targets. Aims to cover the languages
/// atst's typical users (CN / EN-centric developers) are most likely to
/// translate into; the underlying provider accepts any of these strings.
/// For API providers (Google / Microsoft) `LanguageCode.bcp47` maps each
/// display string to the right BCP-47 code under the hood.
enum TargetLanguagePreset {
    static let all: [String] = [
        "简体中文",
        "繁體中文",
        "English",
        "日本語",
        "한국어",
        "Français",
        "Deutsch",
        "Español",
        "Italiano",
        "Português",
        "Русский"
    ]
}

/// Small removable pill used to display selected OCR languages. Reads as a
/// chip / tag — recognisable from countless modern settings UIs. The ×
/// button only renders when `onRemove` is set, so callers can disable
/// removal (e.g. for the last remaining language to keep OCR functional).
private struct LanguageChip: View {
    let name: String
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help(L.pick("Remove", "移除"))
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, onRemove == nil ? 7 : 4)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

/// Lightweight flow layout (wrap-to-next-line) used by the OCR language
/// chips row. Built on SwiftUI's native `Layout` protocol — available on
/// our deployment target so the implementation stays short.
private struct FlowLayoutWrapping: Layout {
    var spacing: CGFloat = 4
    var runSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + runSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Two passes: row-break the children first so we know each row's
        // max height, then place each child vertically centered within
        // its row. Single-pass placement (place top-aligned as we go)
        // was visibly wrong for heterogeneous rows — the OCR chip with
        // an embedded × hit-target sits 2pt taller than the "+ 添加"
        // menu pill, so they ended up top-aligned but center-misaligned.
        var rows: [[Int]] = [[]]
        var rowHeights: [CGFloat] = [0]
        var x: CGFloat = 0
        for (idx, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.width, x > 0 {
                rows.append([])
                rowHeights.append(0)
                x = 0
            }
            rows[rows.count - 1].append(idx)
            rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
            x += size.width + spacing
        }

        var y: CGFloat = bounds.minY
        for (rowIdx, row) in rows.enumerated() {
            let rowHeight = rowHeights[rowIdx]
            var rowX: CGFloat = bounds.minX
            for idx in row {
                let subview = subviews[idx]
                let size = subview.sizeThatFits(.unspecified)
                let dy = (rowHeight - size.height) / 2
                subview.place(at: CGPoint(x: rowX, y: y + dy), proposal: ProposedViewSize(size))
                rowX += size.width + spacing
            }
            y += rowHeight + runSpacing
        }
    }
}
