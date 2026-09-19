import SwiftUI

struct NotificationSettingsView: View {
    @EnvironmentObject var store: HUDStore
    @State private var config = NotificationConfig()
    @State private var loaded = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        // Two sections, because the page governs two different things and the
        // row that sets how long the island stays up does not belong under a
        // header about who gets one.
        SettingsSection("谁来的消息要弹出") {
            SettingsToggleRow("群里 @ 我的消息", subtitle: "收到群聊 @ 时展开浮窗。关掉只是不弹，消息仍在收件箱。", isOn: $config.atMention)
            SettingsRowDivider()
            SettingsToggleRow("重点关注的人", subtitle: "重点联系人、以及群里你指定的重点成员，说话时弹出。", isOn: $config.important)
            SettingsRowDivider()
            // The old second sentence promised 关注的群不会弹出每一条闲聊. That
            // was only true while 提醒范围 is 只提醒我关注的人; under 全部未读
            // 都提醒 this switch pops every message in every room. 已经进入
            // 收件箱 already carries the honest boundary.
            SettingsToggleRow("关注对话的普通更新", subtitle: "开启后，已经进入收件箱的普通消息也会弹出。", isOn: $config.allWhitelist)
        }
        SettingsSection("弹出后停留多久") {
            SettingsRow("展示时间", subtitle: "鼠标移入后可继续阅读和操作。") {
                Picker("展示时间", selection: $config.durationSeconds) {
                    ForEach(Array(Set([3, 5, 8, 15, config.durationSeconds])).sorted(), id: \.self) { seconds in
                        Text("\(seconds) 秒").tag(seconds)
                    }
                }.labelsHidden().frame(width: 100)
            }
            SettingsRowDivider()
            VStack(alignment: .leading, spacing: 8) {
                Text("主动提醒发出的系统通知（VIP、承诺、多条未回、紧急待回复）在 macOS 的通知设置里管理。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error {
                    HStack {
                        Text(error).foregroundStyle(.red)
                        Spacer()
                        Button("重试保存", action: save)
                    }.font(.callout)
                } else {
                    Text(saved ? "设置已保存" : "更改会自动保存，即时生效")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12)
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
            self.error = "提醒设置未保存，请重试。"
            saved = false
        }
    }
}
