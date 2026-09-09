import AppKit
import SwiftUI

/// Compact first-run AI setup that stays inside the introduction window.
struct FirstLaunchAISetupView: View {
    @EnvironmentObject private var store: HUDStore

    @State private var providerID = "deepseek"
    @State private var apiKey = ""
    @State private var model = ""
    @State private var models: [String] = []
    @State private var testResult = ""
    @State private var isTesting = false
    @State private var saveError: String?
    @State private var didLoad = false
    @State private var testRequestID = UUID()

    private var presets: [AIProvider] {
        AIProvider.builtIn.filter { ["deepseek", "moonshot", "zhipu", "openai-codex"].contains($0.id) }
    }

    private var provider: AIProvider? { AIProvider.find(providerID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("AI 服务", selection: $providerID) {
                ForEach(presets) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("AI 服务")
            .onChange(of: providerID) { _, id in
                applyProvider(id)
                persist()
            }

            if provider?.requiresKey == true {
                HStack(spacing: 8) {
                    CompanionClipboardField(
                        text: $apiKey,
                        placeholder: "访问密钥",
                        kind: .secret,
                        secure: true,
                        accessibilityLabel: "访问密钥"
                    )
                    .onChange(of: apiKey) { _, _ in persist() }
                    if let signup = provider?.signupURL, let url = URL(string: signup) {
                        Button("去获取") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.bordered)
                    }
                }
            } else if providerID == "openai-codex" {
                Text("使用这台 Mac 上 Codex 的登录状态，不用填写密钥。测试只发送测试文本。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(isTesting ? "正在测试…" : "测试连接") { testConnection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTesting)
                if !testResult.isEmpty {
                    CompanionCopyableText(text: testResult, lineLimit: 3)
                        .font(.callout)
                        .foregroundStyle(testResult.contains("成功") ? Color.green : Color.orange)
                }
            }

            if let saveError {
                Text(saveError).font(.callout).foregroundStyle(.red)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let config = store.loadAIConfig()
        let storedID = config.provider.providerID
        if presets.contains(where: { $0.id == storedID }) {
            providerID = storedID
            apiKey = config.provider.apiKey
            model = config.provider.model
        }
        applyProvider(providerID, keepKey: !apiKey.isEmpty, keepModel: !model.isEmpty)
        if let record = store.loadAIConnectionEvidence().record(for: currentSlot()) {
            testResult = record.succeeded ? "连接已验证，可以继续。" : "上次测试未通过，请再试一次。"
        }
    }

    private func applyProvider(_ id: String, keepKey: Bool = false, keepModel: Bool = false) {
        guard let preset = AIProvider.find(id) else { return }
        if !keepKey { apiKey = "" }
        models = preset.models
        if !keepModel || model.isEmpty || !preset.models.contains(model) {
            model = preset.models.first ?? ""
        }
        testResult = ""
    }

    private func currentSlot() -> AIProviderSlot {
        AIProviderSlot(
            providerID: providerID,
            baseURL: provider?.baseURL ?? "",
            model: model,
            apiKey: apiKey
        )
    }

    private func persist() {
        var config = store.loadAIConfig()
        config.provider = currentSlot()
        do {
            try store.setSettingJSON("ai", value: config)
            saveError = nil
            NotificationCenter.default.post(name: .hudAIConfigDidChange, object: nil)
        } catch {
            saveError = "AI 设置没有保存成功，请重试。"
        }
    }

    private func testConnection() {
        persist()
        let slot = currentSlot()
        let requestID = UUID()
        let started = Date()
        testRequestID = requestID
        if let error = AISettingsValidation.connectionError(slot, requireModel: true) {
            record(slot: slot, succeeded: false, started: started)
            testResult = error
            return
        }
        isTesting = true
        testResult = ""
        let service = AIService(config: store.loadAIConfig())
        Task {
            do {
                _ = try await service.testSlot(slot)
                await MainActor.run {
                    guard requestID == testRequestID else { return }
                    isTesting = false
                    record(slot: slot, succeeded: true, started: started)
                    testResult = "连接成功，可以继续。"
                }
            } catch {
                await MainActor.run {
                    guard requestID == testRequestID else { return }
                    isTesting = false
                    record(slot: slot, succeeded: false, started: started)
                    testResult = AISettingsValidation.connectionFailure(error)
                }
            }
        }
    }

    private func record(slot: AIProviderSlot, succeeded: Bool, started: Date) {
        var evidence = store.loadAIConnectionEvidence()
        guard evidence.setResult(for: slot, succeeded: succeeded, requestStartedAt: started) else { return }
        try? store.saveAIConnectionEvidence(evidence)
    }
}
