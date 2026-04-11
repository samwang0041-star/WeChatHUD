import SwiftUI

struct SyncSettingsView: View {
    @EnvironmentObject var store: HUDStore

    @State private var dbPath = "auto"
    @State private var interval = 30
    @State private var cacheStrategy: CacheStrategy = .persistent
    @State private var detectedPath = ""

    let intervals = [15, 30, 60, 300]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("数据同步")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)

            // Cache strategy
            VStack(alignment: .leading, spacing: 4) {
                Text("解密缓存位置")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Picker("", selection: $cacheStrategy) {
                    ForEach(CacheStrategy.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: cacheStrategy) { _ in save() }
                Text(cacheStrategy.hint)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
            }

            // DB path
            VStack(alignment: .leading, spacing: 4) {
                Text("微信数据路径")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("auto = 自动检测", text: $dbPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { save() }
                if !detectedPath.isEmpty {
                    Text("检测到: \(detectedPath)")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
            }

            // Poll interval
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
                .onChange(of: interval) { _ in save() }
            }
        }
        .onAppear(perform: load)
    }

    // MARK: - Persistence

    private func load() {
        let cfg = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        dbPath = cfg.wechatDBPath
        interval = cfg.intervalSeconds
        cacheStrategy = cfg.cacheStrategy
        if let path = WeChatReader.autoDetectDBDir() {
            detectedPath = path
        }
    }

    private func save() {
        let cfg = SyncConfig(
            intervalSeconds: interval,
            wechatDBPath: dbPath,
            cacheStrategy: cacheStrategy
        )
        try? store.setSettingJSON("sync", value: cfg)
    }
}
