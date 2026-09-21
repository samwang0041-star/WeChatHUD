import Foundation

/// Directory discovery is a choice of data source, never proof of which
/// account is currently logged into WeChat.
enum SyncConnectionDiagnosis: Equatable {
    case noCandidate
    case needsAccountSelection(Int)
    case directoryMissing
    case directoryUnreadable
    case noDatabaseFiles
    /// The key file is present and readable, but readable by more than its
    /// owner.
    ///
    /// Its own state, not a footnote, and separate from `.ready`: the fix is a
    /// `chmod`, and a key another local account can read is a key disclosed.
    case looseKeyPermissions
    /// The key file parsed as JSON but held no entry this reader understands.
    ///
    /// This is the state that used to be invisible. Every unrecognised entry
    /// was skipped in silence, so the file loaded zero keys and the user was
    /// told there was no key for their database — which sends them hunting for
    /// a new key when the one they have was never the problem.
    case unrecognizedKeyFormat(recognized: Int, rejected: Int)
    case ready(String)

    static func evaluate(
        configuredPath: String,
        candidates: [String],
        exists: (String) -> Bool,
        readable: (String) -> Bool,
        containsDatabase: (String) -> Bool,
        keyMaterial: KeyMaterialFacts = KeyMaterialFacts()
    ) -> Self {
        // Key-material problems come first: a correct directory with an
        // unreadable key file still cannot read anything, and naming the
        // actionable problem before the directory state keeps the user from
        // re-picking a directory that was already right.
        if keyMaterial.loosePermissions { return .looseKeyPermissions }
        if keyMaterial.recognizedEntries == 0 && keyMaterial.rejectedEntries > 0 {
            return .unrecognizedKeyFormat(
                recognized: keyMaterial.recognizedEntries,
                rejected: keyMaterial.rejectedEntries
            )
        }

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

    /// What the loaded key file turned out to contain.
    ///
    /// Passed in rather than read here so the policy stays a pure function of
    /// its inputs and can be tested without a reader, a key file or a disk.
    struct KeyMaterialFacts: Equatable {
        var loosePermissions: Bool = false
        var recognizedEntries: Int = 0
        var rejectedEntries: Int = 0

        init(loosePermissions: Bool = false, recognizedEntries: Int = 0, rejectedEntries: Int = 0) {
            self.loosePermissions = loosePermissions
            self.recognizedEntries = recognizedEntries
            self.rejectedEntries = rejectedEntries
        }

        /// Read the facts off a live reader.
        ///
        /// One place, so the two surfaces that ask for this cannot disagree
        /// about what the reader is reporting. It also makes the whole chain
        /// — reader state to diagnosis — reachable from a test, which is
        /// what the field-by-field constructor could not do: a stored flag that
        /// nothing ever assigned was invisible to tests that supplied the
        /// facts by hand.
        init(reader: WeChatReader) {
            self.loosePermissions = reader.keyFilePermissionsAreLoose
            self.recognizedEntries = reader.recognizedKeyEntryCount
            self.rejectedEntries = reader.rejectedKeyEntryCount
        }
    }

    var message: String {
        switch self {
       case .noCandidate: return "尚未找到微信账号资料。请先在这台 Mac 登录微信；也可以手动选择该账号的资料目录。"
        case .needsAccountSelection(let count): return "发现 \(count) 份账号资料，请明确选择要读取的那一份。资料在不代表该账号当前已登录。"
        case .directoryMissing: return "所选账号资料不存在，请重新选择。不要用其他账号的资料替代当前账号。"
        case .directoryUnreadable: return "所选账号资料不可读。请允许 WeChatHUD 读取整块磁盘，然后重开本应用。"
        case .noDatabaseFiles: return "这里没有该账号的会话资料，请选择这个微信账号自己的资料。"
       case .looseKeyPermissions:
            return "密钥文件权限过宽，同一台 Mac 上的其他账号也能读到。请在「连接与数据」里收紧权限；文件内容不需要重取。"
       case .unrecognizedKeyFormat(let recognized, let rejected):
            return "密钥文件能打开，但 \(rejected) 条记录里没有本应用认识的格式（已识别 \(recognized) 条）。这不代表密钥不对，只代表文件格式不被支持；请先确认拿到的是本机微信的密钥文件。"
        case .ready: return "账号资料可以读取；是否就是当前登录的账号，仍要等一次成功读取。"
        }
    }

    var needsAttention: Bool {
        if case .ready = self { return false }
        return true
    }
}
