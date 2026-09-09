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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(CompanionPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(CompanionPalette.border, lineWidth: 1)
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
                    .font(.system(size: 13))
                    .foregroundColor(iconColor)
                    .frame(width: 28, height: 28, alignment: .center)
                    .background(iconColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
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
