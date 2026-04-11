import SwiftUI

struct SyncSettingsView: View {
    @State private var dbPath = "auto"
    @State private var interval = 30
    @State private var detectedPath = ""

    let intervals = [15, 30, 60, 300]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("数据同步")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 4) {
                Text("微信数据路径")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("auto = 自动检测", text: $dbPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                if !detectedPath.isEmpty {
                    Text("检测到: \(detectedPath)")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("轮询间隔")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Picker("", selection: $interval) {
                    ForEach(intervals, id: \.self) { i in
                        Text(i < 60 ? "\(i)秒" : "\(i / 60)分钟").tag(i)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .onAppear {
            if let path = WeChatReader.autoDetectDBDir() {
                detectedPath = path
            }
        }
    }
}
