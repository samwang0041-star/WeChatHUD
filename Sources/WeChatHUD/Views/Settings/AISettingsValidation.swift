import Foundation

/// Validates connection inputs before network requests; custom endpoints may
/// intentionally be local and need no API key.
enum AISettingsValidation {
    static func connectionError(_ slot: AIProviderSlot, requireModel: Bool) -> String? {
        if requireModel && slot.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写模型名称。"
        }
        if slot.providerID == "openai-codex" { return nil }
        guard let url = URL(string: slot.baseURL),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            return "请填写有效的 http:// 或 https:// 接口地址，不要将密钥放入地址。"
        }
        if AIProvider.find(slot.providerID)?.requiresKey == true && slot.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写此供应商的 API Key。"
        }
        return nil
    }

    static func connectionFailure(_ error: Error) -> String {
        // Backend error bodies can echo credentials or request content. Show
        // recovery guidance rather than serializing arbitrary server strings.
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "请求超时，请检查服务运行状态或稍后重试。"
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet:
                return "无法连接服务，请检查接口地址、网络或本地服务是否启动。"
            default: return "网络请求失败，请检查网络和接口的安全连接。"
            }
        }
        if let error = error as? CodexError {
            switch error {
            case .notLoggedIn, .notChatGPTMode, .missingTokens, .invalidJWT, .missingAccountId, .authRefreshFailed, .authExpired:
                return "Codex 登录状态不可用，请在 Codex 中重新登录后重试。"
            case .usageLimitReached: return "ChatGPT 使用额度已达上限，请稍后重试。"
            case .timeout: return "ChatGPT 请求超时，请稍后重试。"
            case .backendError: return "ChatGPT 服务暂时不可用，请稍后重试。"
            case .responseFailed: return "ChatGPT 未能完成响应，请检查模型权限和服务额度。"
            case .invalidResponse: return "ChatGPT 响应格式不兼容，请更新客户端后重试。"
            }
        }
        if let error = error as? AIError {
            switch error {
            case .invalidURL: return "接口地址无效，请检查 http:// 或 https:// 地址。"
            case .parseFailed: return "服务响应格式不兼容，请检查模型和 OpenAI 兼容接口。"
            case .requestFailed: return "服务拒绝请求，请检查 API Key、模型权限和服务额度。"
            }
        }
        return "连接未完成，请检查服务配置后重试。"
    }
}
