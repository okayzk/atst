import AppKit
import SwiftUI

/// "Dictionary" settings subpage. Source status, the lookup behaviour and
/// the macOS dictionary download guide. The enable switch lives on the
/// General page's "Translation services" row.
struct SettingsDictionaryPage: View {
    @Binding var draft: AppConfiguration
    var save: () -> Void

    @State private var systemHealth: ProviderHealth = .unknown
    @State private var systemDictionaryName: String?
    @State private var showDownloadSheet = false
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        SettingsPage(maxHeight: 500) {
            sourceSection
            lookupSection
            advancedSection
        }
        .onAppear { testSystemDictionary() }
        .onDisappear { testTask?.cancel() }
        .sheet(isPresented: $showDownloadSheet) {
            downloadSheet
        }
    }

    private var sourceSection: some View {
        SettingsSection(title: L.pick("Sources", "来源")) {
            SettingsRow(title: "Youdao") {
                EmptyView()
            }
            SettingsRowDivider()
            systemDictionaryRow
        }
        .disabled(!draft.dictionaryEnabled)
        .opacity(draft.dictionaryEnabled ? 1 : SettingsStyle.disabledOpacity)
    }

    private var systemDictionaryRow: some View {
        SettingsRow(
            title: L.pick("macOS System Dictionary", "macOS 系统词典"),
            subtitle: systemSubtitle
        ) {
            HStack(spacing: 6) {
                Button(L.pick("Manually Download", "手动下载")) {
                    showDownloadSheet = true
                }
                .controlSize(.mini)
                .font(.system(size: 11))

                Button {
                    testSystemDictionary()
                } label: {
                    HStack(spacing: 4) {
                        Text(L.pick("Test", "测试"))
                        ProviderHealthIndicator(health: systemHealth, size: 6)
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.mini)
                .disabled(systemHealth == .checking)
            }
        }
    }

    private var systemSubtitle: String {
        switch systemHealth {
        case .unknown:
            return L.pick("Not checked yet", "尚未检测")
        case .checking:
            return L.pick("Checking…", "检测中…")
        case .reachable:
            return systemDictionaryName ?? L.pick("Installed", "已安装")
        case .unreachable:
            return L.pick(
                "Not installed — use Manually Download",
                "未安装 — 请使用手动下载"
            )
        }
    }

    private var lookupSection: some View {
        SettingsSection(title: L.pick("Lookup", "查词范围")) {
            SettingsToggleRow(
                title: L.pick(
                    "Skip translation when a definition exists",
                    "有词典释义时不调用翻译"
                ),
                isOn: $draft.dictionarySkipsTranslation,
                onChange: save
            )
        }
        .disabled(!draft.dictionaryEnabled)
        .opacity(draft.dictionaryEnabled ? 1 : SettingsStyle.disabledOpacity)
    }

    private var advancedSection: some View {
        SettingsAdvancedSection(title: L.pick("Advanced", "高级")) {
            SettingsRow(
                title: L.pick("Max words", "最大词数")
            ) {
                Picker("", selection: $draft.dictionaryMaxWords) {
                    ForEach(1...4, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .labelsHidden()
                .onChange(of: draft.dictionaryMaxWords) { _ in save() }
            }
            SettingsRowDivider()
            SettingsNotice(
                text: L.pick(
                    "Lookups are sent to Youdao.",
                    "查询词会发送到有道。"
                )
            )
            .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
            .padding(.vertical, SettingsStyle.rowVerticalPadding)
        }
        .disabled(!draft.dictionaryEnabled)
        .opacity(draft.dictionaryEnabled ? 1 : SettingsStyle.disabledOpacity)
    }

    // MARK: - System dictionary test / download guide

    private func testSystemDictionary() {
        testTask?.cancel()
        systemHealth = .checking
        testTask = Task { @MainActor in
            await Task.yield()
            let name = AppleDictionaryService.shared.installedDictionaryName()
            guard !Task.isCancelled else { return }
            if let name {
                systemDictionaryName = name
                systemHealth = .reachable
            } else {
                systemDictionaryName = nil
                systemHealth = .unreachable("Dictionary not installed")
            }
        }
    }

    private var downloadSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.pick("Download the system dictionary", "下载系统词典"))
                .font(.system(size: 14, weight: .semibold))

            Text(L.pick(
                "macOS dictionaries are managed by Dictionary.app. If the English-Chinese dictionary is missing:",
                "macOS 词典由 Dictionary.app 管理。如果没有英汉词典："
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                step(1, L.pick(
                    "Open Dictionary.app.",
                    "打开 Dictionary.app。"
                ))
                step(2, L.pick(
                    "Choose Dictionary → Settings (⌘,).",
                    "选择 Dictionary → 设置（⌘,）。"
                ))
                step(3, L.pick(
                    "Select or download 牛津英汉汉英词典 (Simplified Chinese - English).",
                    "勾选或下载「牛津英汉汉英词典」（Simplified Chinese - English）。"
                ))
                step(4, L.pick(
                    "Return here and press Test.",
                    "回到这里点「测试」。"
                ))
            }
            .font(.system(size: 11))

            HStack {
                Button(L.pick("Open Dictionary", "打开 Dictionary")) {
                    openDictionaryApp()
                }
                Spacer()
                Button(L.pick("Done", "完成")) {
                    showDownloadSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("\(number).")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openDictionaryApp() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Dictionary"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
