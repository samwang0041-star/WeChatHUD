import SwiftUI

struct NotificationSettingsView: View {
    @EnvironmentObject var store: HUDStore
    @State private var config = NotificationConfig()
    @State private var loaded = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        SettingsSection("谁来的消息要弹出") {
            SettingsToggleRow("群里 @ 我的消息", subtitle: "收到群聊 @ 时展开浮窗，帮助你理解上下文。", isOn: $config.atMention)
            SettingsRowDivider()
            SettingsToggleRow("重点关注的人", subtitle: "重点关注联系人的私聊会弹出。", isOn: $config.important)
            SettingsRowDivider()
            SettingsToggleRow("关注对话的普通更新", subtitle: "开启后，普通消息也会展开浮窗；关闭可减少打扰。", isOn: $config.allWhitelist)
            SettingsRowDivider()
            SettingsRow("展示时间", subtitle: "鼠标移入后可继续阅读和操作。") {
                Picker("展示时间", selection: $config.durationSeconds) {
                    ForEach(Array(Set([3, 5, 8, 15, config.durationSeconds])).sorted(), id: \.self) { seconds in
                        Text("\(seconds) 秒").tag(seconds)
                    }
                }.labelsHidden().frame(width: 100)
            }
            SettingsRowDivider()
            VStack(alignment: .leading, spacing: 8) {
                Text("这些开关控制顶部浮窗。承诺到期等系统通知由 macOS 通知设置管理。")
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
