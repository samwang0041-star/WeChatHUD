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
            case .requestFailed(let raw): return requestFailureGuidance(raw)
            }
        }
        return "连接未完成，请检查服务配置后重试。"
    }

    /// Status-aware guidance for `AIError.requestFailed`.
    ///
    /// The raw message is either `"HTTP <status>: <server body>"` or a
    /// client-side rejection with no status at all. Mapping every one of them
    /// to "check your API Key" mislabelled a wrong model name (400/404), a
    /// quota exhausted (429) and a server fault (5xx) as a credential problem —
    /// contradicting the key check that had just passed. The body itself is
    /// never echoed: it can contain credentials or request content.
    static func requestFailureGuidance(_ raw: String) -> String {
        guard let match = raw.range(of: #"^HTTP (\d{3})"#, options: .regularExpression) else {
            if raw.localizedCaseInsensitiveContains("model is empty") {
                return "请选择一个模型。"
            }
            if raw.localizedCaseInsensitiveContains("max_tokens") {
                return "回复被长度上限截断，请缩短输入后重试。"
            }
            if raw.localizedCaseInsensitiveContains("Empty content") {
                return "服务返回了空内容，请重试或更换模型。"
            }
            return "服务返回错误，请检查服务配置后重试。"
        }
        let code = Int(raw[match].dropFirst("HTTP ".count)) ?? 0
        switch code {
        case 400:
            return "服务拒绝了请求（HTTP 400），请确认模型名与该服务匹配。"
        case 401, 403:
            return "服务拒绝了凭据（HTTP \(code)），请检查 API Key 是否正确、是否有额度。"
        case 404:
            return "接口或模型不存在（HTTP 404），请确认服务地址和模型名。"
        case 429:
            return "请求过多或额度用尽（HTTP 429），请稍后重试。"
        case 500...599:
            return "服务内部错误（HTTP \(code)），请稍后重试。"
        default:
            return "服务返回错误（HTTP \(code)），请检查服务配置。"
        }
    }
}
