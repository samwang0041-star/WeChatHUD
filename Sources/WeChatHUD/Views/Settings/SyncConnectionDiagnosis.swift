import Foundation

/// Directory discovery is a choice of data source, never proof of which
/// account is currently logged into WeChat.
enum SyncConnectionDiagnosis: Equatable {
    case noCandidate
    case needsAccountSelection(Int)
    case directoryMissing
    case directoryUnreadable
    case noDatabaseFiles
    case ready(String)

    static func evaluate(configuredPath: String, candidates: [String], exists: (String) -> Bool, readable: (String) -> Bool, containsDatabase: (String) -> Bool) -> Self {
        let root: String
        if configuredPath == "auto" || configuredPath.isEmpty {
            guard !candidates.isEmpty else { return .noCandidate }
            guard candidates.count == 1 else { return .needsAccountSelection(candidates.count) }
            root = candidates[0]
        } else {
            root = (configuredPath as NSString).expandingTildeInPath
        }
        guard exists(root) else { return .directoryMissing }
        guard readable(root) else { return .directoryUnreadable }
        guard containsDatabase(root) else { return .noDatabaseFiles }
        return .ready(root)
    }

    var message: String {
        switch self {
        case .noCandidate: return "尚未找到微信账号资料。请先在这台 Mac 登录微信；也可以手动选择该账号的资料目录。"
        case .needsAccountSelection(let count): return "发现 \(count) 个账号目录，请明确选择要读取的目录。目录存在不代表该账号当前已登录。"
        case .directoryMissing: return "所选目录不存在，请重新选择。不要使用其他账号目录替代当前账号。"
        case .directoryUnreadable: return "所选目录不可读，请检查 macOS 文件访问权限。"
        case .noDatabaseFiles: return "目录内未找到该账号的会话资料，请选择微信账号自己的资料根目录。"
        case .ready: return "目录可读取；账号与密钥是否匹配，仍需以成功同步为准。"
        }
    }

    var needsAttention: Bool {
        if case .ready = self { return false }
        return true
    }
}
