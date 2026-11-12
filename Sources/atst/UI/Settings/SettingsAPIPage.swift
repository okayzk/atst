import SwiftUI

/// "API translation" subpage. Built-in provider enablement lives here;
/// ordering and default-call selection live together on the General page's
/// "Translation services" section. The API master switch also stays on the
/// General page.
struct SettingsAPIPage: View {
    @Binding var draft: AppConfiguration
    var save: () -> Void

    @ObservedObject private var health = ProviderHealthMonitor.shared

    var body: some View {
        SettingsPage(maxHeight: 500) {
            providersSection
            SettingsNotice(
                text: L.pick(
                    "Text is sent to the selected service; Apple runs locally.",
                    "文本会发送到对应服务；Apple 在本机处理。"
                )
            )
            advancedSection
        }
        .onAppear {
            health.checkAPIProviders()
        }
    }

    private var providersSection: some View {
        SettingsSection(title: L.pick("Built-in providers", "内置 provider")) {
            ForEach(Array(draft.apiProviders.enumerated()), id: \.element.id) { index, entry in
                providerRow(index: index, entry: entry)
                if index < draft.apiProviders.count - 1 {
                    SettingsRowDivider()
                }
            }
        }
    }

    private func providerRow(index: Int, entry: APIProviderEntry) -> some View {
        let isAvailable = entry.kind?.isRuntimeAvailable ?? true
        let dimmed = !draft.apiEnabled || !isAvailable
        let subtitle = subtitle(for: entry)
        return SettingsRow(
            title: displayName(for: entry),
            subtitle: subtitle.isEmpty ? nil : subtitle,
            dimmed: dimmed
        ) {
            HStack(spacing: 6) {
                if let kind = entry.kind, kind != .ai {
                    if kind == .system {
                        // Keep the toggle edge aligned with rows that carry
                        // a health dot.
                        Color.clear.frame(width: 6, height: 6)
                    } else {
                        ProviderHealthIndicator(health: health.status(for: kind))
                    }
                }
                Toggle("", isOn: Binding(
                    get: { draft.apiProviders[index].enabled },
                    set: { newValue in
                        draft.apiProviders[index].enabled = newValue
                        save()
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(dimmed)
            }
        }
    }

    private var advancedSection: some View {
        SettingsAdvancedSection(title: L.pick("Advanced", "高级")) {
            SettingsToggleRow(
                title: L.pick("Fallback to other API providers", "自动回退到其他 API 服务"),
                isOn: $draft.apiFallbackEnabled,
                onChange: save
            )
            .opacity(draft.apiEnabled ? 1 : SettingsStyle.disabledOpacity)
            .disabled(!draft.apiEnabled)
        }
    }

    private func displayName(for entry: APIProviderEntry) -> String {
        switch entry.kind {
        case .google: return "Google"
        case .microsoft: return "Microsoft"
        case .deepl: return "DeepL"
        case .system: return "Apple"
        case .ai, .none: return entry.id
        }
    }

    private func subtitle(for entry: APIProviderEntry) -> String {
        switch entry.kind {
        case .google, .microsoft, .deepl:
            return ""
        case .system:
            return entry.kind?.isRuntimeAvailable == false
                ? L.pick("Requires macOS 26", "需 macOS 26")
                : ""
        case .ai, .none:
            return ""
        }
    }
}
