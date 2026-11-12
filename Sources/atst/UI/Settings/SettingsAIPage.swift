import SwiftUI

/// "AI translation" subpage. Endpoint, models and AI-only output options.
/// The enable switch lives on the General page's "Translation services"
/// row; prompts and timeout are secondary and sit in the advanced card.
struct SettingsAIPage: View {
    @Binding var draft: AppConfiguration
    var save: () -> Void
    var debouncedSave: () -> Void

    @State private var aiHealth: ProviderHealth = .unknown

    var body: some View {
        SettingsPage(maxHeight: 500) {
            modelSection
            featuresSection
            advancedSection
        }
    }

    private var modelSection: some View {
        SettingsSection(title: L.pick("Endpoint", "接口")) {
            SettingsTextRow(
                title: "Base URL",
                text: $draft.baseURL,
                placeholder: "http://localhost:11434/v1",
                onChange: debouncedSave
            )
            SettingsSecureRow(
                title: L.pick("API Key (stored locally)", "API Key（本地保存）"),
                text: $draft.apiKey,
                placeholder: L.pick("Optional", "可留空"),
                onChange: debouncedSave
            )
            SettingsTextRow(
                title: L.pick("Translation Model", "翻译模型"),
                text: $draft.textModel,
                placeholder: "text model",
                onChange: debouncedSave
            )
            SettingsTextRow(
                title: L.pick("Screenshot Model", "截图模型"),
                text: $draft.screenshotModel,
                placeholder: "vision model",
                onChange: debouncedSave
            )
            SettingsRowDivider()
            testRow
        }
    }

    private var featuresSection: some View {
        SettingsSection(title: L.pick("Features", "功能")) {
            SettingsToggleRow(
                title: L.pick("Enable phonetic", "启用音标"),
                isOn: $draft.phoneticEnabled,
                onChange: save
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title: L.pick("Enable smart explanation", "启用智能注释"),
                isOn: $draft.smartExplanationEnabled,
                onChange: save
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title: L.pick("Expand by default", "释义默认展开"),
                isOn: $draft.smartExplanationExpandedByDefault,
                onChange: save
            )
            .opacity(draft.smartExplanationEnabled ? 1 : SettingsStyle.disabledOpacity)
            .disabled(!draft.smartExplanationEnabled)
        }
    }

    private var advancedSection: some View {
        SettingsAdvancedSection(title: L.pick("Advanced", "高级")) {
            timeoutRow
            SettingsRowDivider()
            promptEditor(
                title: L.pick("System Prompt", "系统提示词"),
                subtitle: L.pick(
                    "Wrap the answer in <atst-result>.",
                    "译文需用 <atst-result> 包裹。"
                ),
                text: $draft.systemPrompt,
                defaultText: AppConfiguration.defaultConfig.systemPrompt
            )
            SettingsRowDivider()
            promptEditor(
                title: L.pick("Smart Explanation Prompt", "智能注释提示词"),
                subtitle: L.pick(
                    "Content goes into <atst-desc>.",
                    "内容写入 <atst-desc>。"
                ),
                text: $draft.smartExplanationPrompt,
                defaultText: AppConfiguration.defaultConfig.smartExplanationPrompt
            )
        }
    }

    /// Only the AI request honours this; Google / Microsoft use a fixed
    /// 15 s, which is why the row lives here and not in General.
    private var timeoutRow: some View {
        SettingsRow(
            title: L.pick("Timeout", "超时")
        ) {
            HStack(spacing: 4) {
                TextField("10", value: $draft.timeoutSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .onChange(of: draft.timeoutSeconds) { _ in debouncedSave() }
                Text(L.pick("s", "秒"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Manual AI probe. AI is not auto-checked because a probe spends tokens
    /// and depends on the fields currently being edited.
    private var testRow: some View {
        SettingsRow(
            title: L.pick("Connection", "连接测试")
        ) {
            Button {
                testAI()
            } label: {
                HStack(spacing: 5) {
                    Text(L.pick("Test", "测试"))
                    ProviderHealthIndicator(health: aiHealth, size: 6)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .controlSize(.small)
            .disabled(aiHealth == .checking)
        }
    }

    private func testAI() {
        let configuration = draft
        aiHealth = .checking
        Task { @MainActor in
            let health = await ProviderHealthMonitor.shared.checkAI(configuration: configuration)
            aiHealth = health
        }
    }

    private func promptEditor(
        title: String,
        subtitle: String,
        text: Binding<String>,
        defaultText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(SettingsStyle.rowTitleFont)
                    .foregroundStyle(.primary)
                Spacer()
                Button(L.pick("Restore default", "恢复默认")) {
                    text.wrappedValue = defaultText
                    save()
                }
                .controlSize(.mini)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            Text(subtitle)
                .font(SettingsStyle.rowSubtitleFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 170)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: SettingsStyle.cardCornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsStyle.cardCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _ in
                    save()
                }
        }
        .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
    }
}
