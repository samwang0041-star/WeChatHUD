import Foundation

/// Chooses a database root during first connection without inferring an
/// account from directory order or stale process evidence.
enum ConnectionSetupPolicy: Equatable {
    case useConfiguredRoot(String)
    case useProcessEvidence(String)
    case useUniqueCandidate(String)
    case needsUserSelection([String])
    case needsWeChatAccess

    /// A monitor can retain `.accountSwitched` after the user has selected a
    /// new root. Only present the recovery choice while the selected root is
    /// still the root the reader is using; the status alone is not proof that
    /// the newly selected account needs changing.
    static func needsAccountSelection(
        selectedRoot: String?,
        readerRoot: String?,
        syncStatus: SyncStatus
    ) -> Bool {
        guard case .accountSwitched = syncStatus else { return false }
        return rootsMatch(selectedRoot, readerRoot)
    }

    static func hasConfiguredRoot(_ root: String?) -> Bool {
        normalized(root) != nil
    }

    static func rootsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalized(lhs), let rhs = normalized(rhs) else { return false }
        return lhs == rhs
    }

    /// - Parameters:
    ///   - configuredRoot: A path explicitly saved by the user. Empty and
    ///     `auto` mean that no explicit choice exists.
    ///   - candidateRoots: Database roots discovered on disk.
    ///   - processRoots: Database roots observed from the running WeChat
    ///     process. This is already captured evidence; this method does not
    ///     inspect the operating system.
    static func resolve(
        configuredRoot: String?,
        candidateRoots: [String],
        processRoots: [String]
    ) -> Self {
        if let configured = normalized(configuredRoot), !configured.isEmpty {
            return .useConfiguredRoot(configured)
        }

        let candidates = normalizedUnique(candidateRoots)
        let processEvidence = normalizedUnique(processRoots)

        if processEvidence.count == 1,
           let observed = processEvidence.first,
           candidates.contains(observed) {
            return .useProcessEvidence(observed)
        }

        switch candidates.count {
        case 0:
            return .needsWeChatAccess
        case 1:
            return .useUniqueCandidate(candidates[0])
        default:
            return .needsUserSelection(candidates)
        }
    }

    private static func normalizedUnique(_ paths: [String]) -> [String] {
        Array(Set(paths.compactMap(normalized))).sorted()
    }

    private static func normalized(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "auto" else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
