import SwiftUI

// MARK: - macOS System Settings–style building blocks

/// A grouped section with rounded background, matching macOS System Settings.
struct SettingsSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .workspaceRowTitle()
                    .foregroundStyle(.primary)
                    .padding(.leading, 4)
            }
            // Leading, not the default centre.
            //
            // Any child that does not stretch itself — a footnote, a warning
            // banner's sentence, a lone button under a row — was being centred
            // in the card. Measured in the shipped build: 提醒方式's footnote sat
            // at x1168–1791 inside a card spanning x528–2444 whose every row
            // starts at x561. Four pages had the same floating block, and it is
            // the one layout rule in `ui-language.md` that was being broken
            // everywhere at once (header, content and cards share one left edge).
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CompanionPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(CompanionPalette.border, lineWidth: CompanionAccessibility.cardEdgeWidth)
            )
        }
    }
}

/// A single row inside a SettingsSection — label left, accessory right.
struct SettingsRow<Accessory: View>: View {
    let label: String
    let subtitle: String?
    let icon: String?
    let iconColor: Color
    @ViewBuilder let accessory: () -> Accessory

    init(
        _ label: String,
        subtitle: String? = nil,
        icon: String? = nil,
        iconColor: Color = .secondary,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.label = label
        self.subtitle = subtitle
        self.icon = icon
        self.iconColor = iconColor
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .workspaceRowTitle()
                    .foregroundColor(iconColor)
                    .frame(width: 28, height: 28, alignment: .center)
                    .background(iconColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .companionFont(size: WorkspaceType.rowTitle, weight: .medium)
                    .foregroundColor(.primary)
                if let subtitle {
                    Text(subtitle)
                        .workspaceBody()
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// A divider between rows inside a SettingsSection.
struct SettingsRowDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 16).opacity(0.65)
    }
}

/// Toggle row — the most common pattern.
struct SettingsToggleRow: View {
    let label: String
    let subtitle: String?
    @Binding var isOn: Bool

    init(_ label: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.label = label
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(label, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(label)
                .accessibilityHint(subtitle ?? "")
        }
    }
}
