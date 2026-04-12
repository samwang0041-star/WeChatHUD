import SwiftUI

struct SyncSettingsView: View {
    @EnvironmentObject var store: HUDStore

    @State private var dbPath = "auto"
    @State private var interval = 30
    @State private var cacheStrategy: CacheStrategy = .temporary
    @State private var detectedPath = ""
    @State private var didLoad = false
    @State private var showSaved = false

    let intervals = [15, 30, 60, 300]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showSaved {
                Text("已保存")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.green)
                    .transition(.opacity)
            }

            // Cache strategy
            VStack(alignment: .leading, spacing: 4) {
                Text("解密缓存位置")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                Picker("", selection: $cacheStrategy) {
                    ForEach(CacheStrategy.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: cacheStrategy) { save() }
                Text(cacheStrategy.hint)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
            }

            // DB path
            VStack(alignment: .leading, spacing: 4) {
                Text("微信数据路径")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                TextField("auto = 自动检测", text: $dbPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
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
                    .foregroundColor(.white.opacity(0.6))
                Picker("", selection: $interval) {
                    ForEach(intervals, id: \.self) { i in
                        Text(i < 60 ? "\(i)秒" : "\(i / 60)分钟").tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: interval) { save() }
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            load()
        }
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
        showSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSaved = false }
    }
}
