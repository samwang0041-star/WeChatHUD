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
            return "请填写有效的 http:// 或 https:// 接口地址，不要把访问凭据写进地址。"
        }
        if scheme == "http", !AIEndpointPolicy.isLoopbackHost(host) {
            return "远程 AI 接口必须使用 https://。仅本机（localhost / 127.0.0.1 / ::1）允许 http://"
        }
        if AIProvider.find(slot.providerID)?.requiresKey == true && slot.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写此供应商的访问凭据。"
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
            case .notLoggedIn, .notChatGPTMode, .missingTokens, .invalidJWT, .missingAccountId, .authRefreshFailed, .authExpired, .insecureAuthFile:
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
            case .insecureCleartext: return "远程 AI 接口必须使用 https://，仅本机允许 http://。"
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
            return "服务拒绝了这次请求，请确认模型名与该服务匹配。"
        case 401, 403:
            return "服务拒绝了访问凭据，请检查是否填写正确、是否还有额度。"
        case 404:
            return "找不到这个接口或模型，请确认服务地址和模型名。"
        case 429:
            return "请求过多或额度用尽，请稍后重试。"
        case 500...599:
            return "服务暂时出了问题，请稍后重试。"
        default:
            return "服务返回错误，请检查服务配置。"
        }
    }

    /// Last-mile filter before a mapped sentence is painted. Raw transport
    /// leftovers collapse here; already-mapped Chinese — including sentences
    /// that mention 模型 or https — passes through so a missing model is not
    /// rewritten as "please pick one".
    static func displayable(_ message: String) -> String {
        if message.range(of: #"HTTP \d{3}"#, options: .regularExpression) != nil {
            return requestFailureGuidance(message)
        }
        if message.localizedCaseInsensitiveContains("api key")
            || message.localizedCaseInsensitiveContains("token") {
            return "请补充该服务要求的访问凭据。"
        }
        return message
    }
}
