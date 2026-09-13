import SwiftUI

enum NotificationSettingsCopy {
    static let popupNone = "现在浮窗不会自己弹出。"
    static let atMentionPart = "群 @"
    static let importantPart = "重点的人"
    static let whitelistPart = "关注里的普通消息"
    static let atMentionTitle = "群里 @ 我的消息"
    static let atMentionSubtitle = "有人 @ 你时浮窗会展开。"
    static let importantTitle = "重点关注的人"
    static let importantSubtitle = "这些人私聊会弹出。"
    static let whitelistTitle = "关注的人普通说话"
    static let whitelistSubtitle = "已经进收件箱的私聊也会弹出。群闲聊不会一条条弹。"
    static let durationTitle = "展示时间"
    static let durationSubtitle = "鼠标移入后可继续看。"
    static let durationDisclosure = "还要改展示多久"
    static let canvasNote = "这里管顶部浮窗。承诺到期走系统通知。"
    static let saved = "已经记下。"
    static let unsaved = "改了就生效。"
    static let saveFailed = "没记住。点「再试一次」。"
    static let saveRetry = "再试一次"

    static func popupLine(atMention: Bool, important: Bool, allWhitelist: Bool) -> String {
        var parts: [String] = []
        if atMention { parts.append(atMentionPart) }
        if important { parts.append(importantPart) }
        if allWhitelist { parts.append(whitelistPart) }
        if parts.isEmpty { return popupNone }
        return "现在会弹出：\(parts.joined(separator: "、"))。"
    }
}

struct NotificationSettingsView: View {
    @EnvironmentObject var store: HUDStore
    @State private var config = NotificationConfig()
    @State private var loaded = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NotificationSettingsCopy.popupLine(
                atMention: config.atMention,
                important: config.important,
                allWhitelist: config.allWhitelist
            ))
            .workspaceTitle()
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(NotificationSettingsCopy.popupLine(
                atMention: config.atMention,
                important: config.important,
                allWhitelist: config.allWhitelist
            ))

            SettingsSection("谁来的消息要弹出") {
                SettingsToggleRow(NotificationSettingsCopy.atMentionTitle, subtitle: NotificationSettingsCopy.atMentionSubtitle, isOn: $config.atMention)
                SettingsRowDivider()
                SettingsToggleRow(NotificationSettingsCopy.importantTitle, subtitle: NotificationSettingsCopy.importantSubtitle, isOn: $config.important)
                SettingsRowDivider()
                SettingsToggleRow(NotificationSettingsCopy.whitelistTitle, subtitle: NotificationSettingsCopy.whitelistSubtitle, isOn: $config.allWhitelist)
                SettingsRowDivider()
                DisclosureGroup(NotificationSettingsCopy.durationDisclosure) {
                    SettingsRow(NotificationSettingsCopy.durationTitle, subtitle: NotificationSettingsCopy.durationSubtitle) {
                        Picker(NotificationSettingsCopy.durationTitle, selection: $config.durationSeconds) {
                            ForEach(Array(Set([3, 5, 8, 15, config.durationSeconds])).sorted(), id: \.self) { seconds in
                                Text("\(seconds) 秒").tag(seconds)
                            }
                        }.labelsHidden().frame(width: 100)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(NotificationSettingsCopy.canvasNote)
                    .workspaceMeta()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(error)
                            .workspaceMeta()
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(NotificationSettingsCopy.saveRetry, action: save)
                            .buttonStyle(CompanionPressStyle())
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(saved ? NotificationSettingsCopy.saved : NotificationSettingsCopy.unsaved)
                        .workspaceMeta()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            config = store.getSettingJSON("notification", as: NotificationConfig.self) ?? NotificationConfig()
            loaded = true
        }
        .onChange(of: config.atMention) { save() }
        .onChange(of: config.important) { save() }
        .onChange(of: config.allWhitelist) { save() }
        .onChange(of: config.durationSeconds) { save() }
    }

    private func save() {
        guard loaded else { return }
        do {
            try store.setSettingJSON("notification", value: config)
            error = nil
            saved = true
        } catch {
            self.error = NotificationSettingsCopy.saveFailed
            saved = false
        }
    }
}
