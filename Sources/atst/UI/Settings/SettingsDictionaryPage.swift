import AppKit
import SwiftUI

/// "Dictionary" settings subpage. The card itself lives in the tooltip; this
/// page owns the enable switch, source status, the macOS dictionary download
/// guide and the lookup word limit.
struct SettingsDictionaryPage: View {
    @Binding var draft: AppConfiguration
    var save: () -> Void

    @State private var systemHealth: ProviderHealth = .unknown
    @State private var systemDictionaryName: String?
    @State private var showDownloadSheet = false
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusSection
                sourceSection
                lookupSection
                noticeSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 500)
        .onAppear { testSystemDictionary() }
        .onDisappear { testTask?.cancel() }
        .sheet(isPresented: $showDownloadSheet) {
            downloadSheet
        }
    }

    private var statusSection: some View {
        SettingsSection(title: L.pick("Status", "状态")) {
            SettingsToggleRow(
                title: L.pick("Enable dictionary lookup", "启用查词"),
                subtitle: L.pick(
                    "Show a dictionary card for single words and fixed phrases. Youdao is the primary source; the macOS dictionary is the offline fallback.",
                    "为单词和固定搭配显示词典卡片。主源为有道，macOS 系统词典作为离线兜底。"
                ),
                isOn: $draft.dictionaryEnabled,
                onChange: save
            )
        }
    }

    private var sourceSection: some View {
        SettingsSection(title: L.pick("Sources", "来源")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Youdao")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(L.pick(
                        "Keyless web dictionary · primary",
                        "免 key 网页词典 · 主源"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().padding(.horizontal, 10)
            systemDictionaryRow
        }
        .disabled(!draft.dictionaryEnabled)
        .opacity(draft.dictionaryEnabled ? 1 : 0.45)
    }

    private var systemDictionaryRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L.pick("macOS System Dictionary", "macOS 系统词典"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(systemSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(L.pick("Manually Download", "手动下载")) {
                showDownloadSheet = true
            }
            .controlSize(.mini)
            .font(.system(size: 10))

            Button {
                testSystemDictionary()
            } label: {
                HStack(spacing: 4) {
                    Text(L.pick("Test", "测试"))
                    ProviderHealthIndicator(health: systemHealth, size: 6)
                }
                .font(.system(size: 10, weight: .medium))
            }
            .controlSize(.mini)
            .disabled(systemHealth == .checking)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
            Divider().padding(.horizontal, 10)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L.pick("Max words", "最大词数"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(L.pick(
                        "Longer selections are translated normally.",
                        "超过词数的选区只做普通翻译。"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .disabled(!draft.dictionaryEnabled)
        .opacity(draft.dictionaryEnabled ? 1 : 0.45)
    }

    private var noticeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(L.pick("About dictionary sources", "关于词典来源"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(L.pick(
                "Youdao is an unofficial web endpoint; the word or phrase is sent to dict.youdao.com. If it fails, the app tries the local system dictionary and hides the card when both miss. When AI translation is enabled, the dictionary card and the AI explanation are both shown.",
                "有道是非官方网页接口，查询时会把单词或短语发送到 dict.youdao.com。失败时会尝试本地系统词典，两者都没有结果就隐藏词典卡片。启用 AI 翻译时，词典卡片和 AI 释义会同时显示。"
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
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
