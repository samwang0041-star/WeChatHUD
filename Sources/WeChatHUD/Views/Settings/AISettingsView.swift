import SwiftUI

struct AISettingsView: View {
    @State private var baseURL = "http://127.0.0.1:11434/v1"
    @State private var model = "qwen2.5:14b"
    @State private var apiKey = ""
    @State private var testResult = ""
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI 配置")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)

            settingsField("API 地址", text: $baseURL)
            settingsField("模型", text: $model)
            settingsField("API Key", text: $apiKey, isSecure: true)

            HStack {
                Button(action: testConnection) {
                    HStack(spacing: 4) {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        Text(isTesting ? "测试中..." : "测试连接")
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.3))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(isTesting)

                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.system(size: 11))
                        .foregroundColor(testResult.contains("成功") ? .green : .red)
                }
            }
        }
    }

    private func settingsField(_ label: String, text: Binding<String>, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if isSecure {
                SecureField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            } else {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = ""
        let cfg = AIConfig(baseURL: baseURL, model: model, apiKey: apiKey)
        Task {
            let service = AIService(config: cfg)
            do {
                let result = try await service.testConnection()
                await MainActor.run {
                    testResult = "连接成功: \(result.prefix(20))"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "连接失败: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}
