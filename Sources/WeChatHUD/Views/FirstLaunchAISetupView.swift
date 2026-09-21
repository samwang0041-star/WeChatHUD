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
    @State private var testPassed = false
    @State private var isTesting = false
    @State private var saveError: String?
    @State private var didLoad = false
   @State private var testRequestID = UUID()
   @State private var isSaving = false
    @State private var signupOpenError: String?

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
                        placeholder: "访问凭据",
                        kind: .secret,
                        secure: true,
                        accessibilityLabel: "访问凭据"
                    )
                    .onChange(of: apiKey) { _, _ in persist() }
                   if let signup = provider?.signupURL, let url = URL(string: signup) {
                        Button("去获取") { openSignup(url) }
                            .buttonStyle(CompanionPressStyle())
                            .accessibilityLabel("打开获取访问凭据的页面")
                   }
               }
            } else if providerID == "openai-codex" {
                Text("使用这台 Mac 上 Codex 的登录状态，不用填写访问凭据。测试只发送测试文本。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                   .fixedSize(horizontal: false, vertical: true)
           }

            if let signupOpenError {
                Text(signupOpenError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .transition(.companionStatusReveal)
            }

           HStack(spacing: 10) {
               Button(isTesting ? "正在测试…" : "测试连接") { testConnection() }
                    .tint(CompanionPalette.accent)
                    .buttonStyle(.borderedProminent)
                    .disabled(isTesting || isSaving)
                    .help(isSaving ? "正在保存更改" : (isTesting ? "正在测试连接" : ""))
                    .accessibilityHint(isSaving ? "正在保存更改" : (isTesting ? "正在测试连接" : ""))
                if !testResult.isEmpty {
                    CompanionCopyableText(text: testResult, lineLimit: 3)
                        .font(.callout)
                        .foregroundStyle(testPassed ? Color.green : Color.orange)
                        .transition(.companionStatusReveal)
                }
            }

            if let saveError {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(saveError).font(.callout).foregroundStyle(.red)
                    Button(action: retryPersist) {
                        Text(isSaving ? "正在保存…" : "重试保存")
                    }
                    .controlSize(.small)
                    .disabled(isSaving)
                    .help(isSaving ? "正在保存更改" : "")
                    .accessibilityHint(isSaving ? "正在保存更改" : "")
                }
                .transition(.companionStatusReveal)
            }
        }
        .onAppear(perform: load)
       .companionAnimation(CompanionMotion.ease(), value: saveError)
       .companionAnimation(CompanionMotion.ease(), value: testResult)
        .companionAnimation(CompanionMotion.ease(), value: signupOpenError)
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
            testPassed = record.succeeded
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
        signupOpenError = nil
   }

    private func currentSlot() -> AIProviderSlot {
        AIProviderSlot(
            providerID: providerID,
            baseURL: provider?.baseURL ?? "",
            model: model,
            apiKey: apiKey
        )
    }

    @discardableResult
    private func persist() -> Bool {
        var config = store.loadAIConfig()
        config.provider = currentSlot()
        do {
            try store.setSettingJSON("ai", value: config)
            saveError = nil
            NotificationCenter.default.post(name: .hudAIConfigDidChange, object: nil)
            return true
        } catch {
            saveError = "AI 设置没有保存成功，请重试。"
            return false
        }
    }

    private func retryPersist() {
        guard !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            _ = persist()
        }
    }

    private func testConnection() {
        persist()
        let slot = currentSlot()
        let requestID = UUID()
        let started = Date()
        testRequestID = requestID
       if let error = AISettingsValidation.connectionError(slot, requireModel: true) {
            testPassed = false
            testResult = stamped(error, saved: record(slot: slot, succeeded: false, started: started))
           return
       }
       isTesting = true
        testPassed = false
        testResult = ""
        let service = AIService(config: store.loadAIConfig())
        Task {
            do {
                _ = try await service.testSlot(slot)
                await MainActor.run {
                    guard requestID == testRequestID else { return }
                    isTesting = false
                   let saved = record(slot: slot, succeeded: true, started: started)
                    testPassed = true
                   testResult = saved
                       ? "连接成功，可以继续。"
                       : "连接成功，但测试结果未保存，请重试。"
                }
            } catch {
                await MainActor.run {
                    guard requestID == testRequestID else { return }
                   isTesting = false
                    testPassed = false
                   testResult = stamped(
                       AISettingsValidation.displayable(AISettingsValidation.connectionFailure(error)),
                       saved: record(slot: slot, succeeded: false, started: started)
                   )
                }
            }
        }
    }

    @discardableResult
    private func record(slot: AIProviderSlot, succeeded: Bool, started: Date) -> Bool {
        var evidence = store.loadAIConnectionEvidence()
        guard evidence.setResult(for: slot, succeeded: succeeded, requestStartedAt: started) else {
            return false
        }
        do {
            try store.saveAIConnectionEvidence(evidence)
            return true
        } catch {
            return false
        }
    }

   private func stamped(_ message: String, saved: Bool) -> String {
       saved ? message : message + "；测试结果未保存，请重试"
   }

    private func openSignup(_ url: URL) {
        guard NSWorkspace.shared.open(url) else {
            signupOpenError = "没能打开获取访问凭据的页面，请在浏览器里打开供应商网站。"
            return
        }
        signupOpenError = nil
    }
}
