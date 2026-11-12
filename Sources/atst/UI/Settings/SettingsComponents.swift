import SwiftUI

/// Shared type/spacing tokens for every settings page. Keeping these in one
/// place is what stops rows from drifting into 11/12pt labels and 6/7/8pt
/// vertical padding as pages are edited independently.
enum SettingsStyle {
    static let sectionSpacing: CGFloat = 14
    static let rowHorizontalPadding: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 9
    static let contentHorizontalPadding: CGFloat = 14
    static let contentVerticalPadding: CGFloat = 12
    static let cardCornerRadius: CGFloat = 8
    static let disabledOpacity: Double = 0.4
    static let controlWidth: CGFloat = 170
    static let numberFieldWidth: CGFloat = 80

    static let sectionTitleFont = Font.system(size: 13, weight: .semibold)
    static let rowTitleFont = Font.system(size: 13, weight: .medium)
    static let rowSubtitleFont = Font.system(size: 11)
    static let bodyFont = Font.system(size: 11)
}

/// Page container shared by the General page and all subpages. Guarantees
/// the same scroll behaviour, side padding and section rhythm everywhere.
struct SettingsPage<Content: View>: View {
    var maxHeight: CGFloat = 500
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
                content()
            }
            .padding(.horizontal, SettingsStyle.contentHorizontalPadding)
            .padding(.vertical, SettingsStyle.contentVerticalPadding)
        }
        .frame(maxHeight: maxHeight)
    }
}

/// Standard settings row: title (+ optional subtitle) on the left, any
/// trailing control on the right. Replaces the hand-built copies of this
/// layout that each page used to carry.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var dimmed: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(SettingsStyle.rowTitleFont)
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SettingsStyle.rowSubtitleFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
        .opacity(dimmed ? SettingsStyle.disabledOpacity : 1)
        .disabled(dimmed)
    }
}

/// The one divider inset used inside section cards.
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
    }
}

/// Bottom-of-page collapsible section. Uses a plain Button rather than
/// `DisclosureGroup` so the chevron and content align with the section
/// headers instead of inheriting DisclosureGroup's default indent.
struct SettingsAdvancedSection<Content: View>: View {
    let title: String
    @State private var expanded: Bool
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self._expanded = State(initialValue: initiallyExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title)
                        .font(SettingsStyle.sectionTitleFont)
                        .foregroundStyle(.primary.opacity(0.85))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)

            if expanded {
                VStack(spacing: 0) {
                    content()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Info / warning copy used at the bottom of subpages. Replaces the three
/// different footnote and banner implementations pages used to carry.
struct SettingsNotice: View {
    enum Style {
        case info
        case warning
    }

    let text: String
    var title: String? = nil
    var style: Style = .info

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(style == .warning ? Color.orange : Color.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(text)
                    .font(SettingsStyle.bodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, style == .warning ? 10 : 4)
        .padding(.vertical, style == .warning ? 8 : 0)
        .background(
            Group {
                if style == .warning {
                    RoundedRectangle(cornerRadius: SettingsStyle.cardCornerRadius, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                }
            }
        )
        .overlay(
            Group {
                if style == .warning {
                    RoundedRectangle(cornerRadius: SettingsStyle.cardCornerRadius, style: .continuous)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 0.5)
                }
            }
        )
    }
}

/// Section header + rows used by every settings page. Rows sit directly
/// on the window's single glass surface (same as the translation tooltip)
/// and are separated by inset rules instead of an extra card layer.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SettingsStyle.sectionTitleFont)
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
        }
    }
}

/// Small reachability dot used next to service names and the AI Test
/// button. Green = reachable, red = unavailable, orange = probing, gray =
/// not checked yet.
struct ProviderHealthIndicator: View {
    let health: ProviderHealth
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .help(helpText)
            .accessibilityLabel(Text(helpText))
    }

    private var color: Color {
        switch health {
        case .unknown: return Color.secondary.opacity(0.35)
        case .checking: return .orange
        case .reachable: return .green
        case .unreachable: return .red
        }
    }

    private var helpText: String {
        switch health {
        case .unknown:
            return L.pick("Not checked yet", "尚未检测")
        case .checking:
            return L.pick("Checking…", "检测中…")
        case .reachable:
            return L.pick("Reachable", "可达")
        case .unreachable(let detail):
            return "\(L.pick("Unreachable", "不可达")): \(detail)"
        }
    }
}

/// Two-line toggle row used for feature switches (audio playback, smart
/// explanation, etc).
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String = ""
    @Binding var isOn: Bool
    var onChange: () -> Void = {}

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle.isEmpty ? nil : subtitle) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .onChange(of: isOn) { _ in
                    onChange()
                }
        }
    }
}

/// Permission status row (Accessibility / Screen Recording). Shows a
/// coloured dot + free-form requirement label and an open-system-settings
/// button. Status is polled by the page, so there's no manual refresh.
struct SettingsPermissionRow: View {
    let title: String
    let requirement: String
    let granted: Bool
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(SettingsStyle.rowTitleFont)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Circle()
                        .fill(granted ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(L.pick(
                        "\(requirement) · \(granted ? "Granted" : "Not granted")",
                        "\(requirement) · \(granted ? "已授权" : "未授权")"
                    ))
                    .font(SettingsStyle.rowSubtitleFont)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button(action: openSettings) {
                Image(systemName: "gear")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L.pick("Open System Settings", "打开系统设置"))
        }
        .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
    }
}

/// Labelled text field with the secondary-coloured caption layout used
/// throughout the settings panel.
struct SettingsTextRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var onChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(SettingsStyle.rowTitleFont)
                .foregroundStyle(.primary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: text) { _ in onChange() }
        }
        .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
    }
}

/// SecureField variant of `SettingsTextRow`.
struct SettingsSecureRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var onChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(SettingsStyle.rowTitleFont)
                .foregroundStyle(.primary)
            SecureField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: text) { _ in onChange() }
        }
        .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
    }
}
