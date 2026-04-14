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
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
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
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(iconColor)
                    .frame(width: 16, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A divider between rows inside a SettingsSection.
struct SettingsRowDivider: View {
    var body: some View {
        Divider().padding(.leading, 12)
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
        }
    }
}
