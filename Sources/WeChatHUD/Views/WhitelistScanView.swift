import SwiftUI

/// Batch whitelist scan UI shown in ContactsSettingsView.
/// Scans recent unread contacts (not already whitelisted) through the
/// AIWhitelistCategorizer and lets the user accept or reject per-item.
struct WhitelistScanView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject var monitor: ChatMonitor

    @State private var isScanning = false
    @State private var scanned = 0
    @State private var total = 0
    @State private var results: [ScanResult] = []
    @State private var dismissedKeys: Set<String> = []

    struct ScanResult: Identifiable {
        let id: String  // chatUsername
        let chatUsername: String
        let displayName: String
        let isGroup: Bool
        let suggestion: AIWhitelistCategorizer.Suggestion
        var accepted: Bool = false
        var rejected: Bool = false
    }

    private var pendingResults: [ScanResult] {
        results.filter { !$0.accepted && !$0.rejected && !dismissedKeys.contains($0.id) }
    }

    private var acceptedResults: [ScanResult] {
        results.filter { $0.accepted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 白名单扫描")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text("扫描未关注的联系人，AI 自动建议是否加入白名单")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                Button(action: startScan) {
                    HStack(spacing: 4) {
                        if isScanning {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                        }
                        Text(isScanning ? "扫描中…" : "开始扫描")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isScanning)
            }

            // Progress bar
            if isScanning || (total > 0 && scanned < total) {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: total > 0 ? Double(scanned) / Double(total) : 0)
                        .progressViewStyle(.linear)
                    Text("已扫描 \(scanned) / \(total)")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            // Results
            if !results.isEmpty {
                if !pendingResults.isEmpty {
                    HStack {
                        Text("扫描结果 (\(pendingResults.count) 条建议)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                        Spacer()
                        // Bulk actions
                        Button("全部接受") {
                            acceptAll()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)

                        Button("全部忽略") {
                            rejectAll()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    VStack(spacing: 2) {
                        ForEach(pendingResults) { result in
                            scanResultRow(result)
                        }
                    }
                    .padding(6)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(8)
                } else if !acceptedResults.isEmpty {
                    Text("已接受 \(acceptedResults.count) 个建议")
                        .font(.system(size: 10))
                        .foregroundColor(.green.opacity(0.7))
                } else {
                    Text("已处理所有建议")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }

    private func scanResultRow(_ result: ScanResult) -> some View {
        HStack(spacing: 8) {
            // Category badge
            let catLabel = result.suggestion.category == "work" ? "工作" :
                           result.suggestion.category == "life" ? "生活" : "其他"
            let catColor: Color = result.suggestion.category == "work" ? .blue :
                                  result.suggestion.category == "life" ? .green : .gray

            Text(catLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(catColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(catColor.opacity(0.15))
                .cornerRadius(3)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(result.suggestion.reason)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(2)
            }

            Spacer()

            Text("\(Int(result.suggestion.confidence * 100))%")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.35))
                .monospacedDigit()

            Button("接受") {
                accept(result)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)

            Button("忽略") {
                reject(result)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // MARK: - Actions

    private func accept(_ result: ScanResult) {
        let category = result.suggestion.whitelistCategory
        try? store.addToWhitelist(
            username: result.chatUsername,
            displayName: result.displayName,
            isGroup: result.isGroup,
            category: category,
            attentionLevel: .watch
        )
        if let idx = results.firstIndex(where: { $0.id == result.id }) {
            results[idx].accepted = true
        }
    }

    private func reject(_ result: ScanResult) {
        dismissedKeys.insert(result.id)
        if let idx = results.firstIndex(where: { $0.id == result.id }) {
            results[idx].rejected = true
        }
    }

    private func acceptAll() {
        for result in pendingResults {
            accept(result)
        }
    }

    private func rejectAll() {
        for result in pendingResults {
            reject(result)
        }
    }

    private func startScan() {
        guard !isScanning else { return }
        isScanning = true
        scanned = 0
        results = []
        dismissedKeys = []

        Task {
            // Gather candidates: recent unread items from monitor that aren't whitelisted.
            // Fall back to a sample of known contacts for demonstration if no unread items.
            var candidates: [(username: String, displayName: String, isGroup: Bool)] = []

            let unreadCandidates = monitor.unreadItems
                .filter { !$0.isWhitelisted }
                .map { (username: $0.chatUsername, displayName: $0.chatName, isGroup: $0.chatUsername.contains("@chatroom")) }

            // Deduplicate by username
            var seen = Set<String>()
            for c in unreadCandidates {
                if seen.insert(c.username).inserted {
                    candidates.append(c)
                }
            }

            // Also check monitor suggestions already computed
            for (username, suggestion) in monitor.whitelistSuggestions {
                if !seen.contains(username) {
                    seen.insert(username)
                    let isGroup = username.contains("@chatroom")
                    candidates.append((username: username, displayName: username, isGroup: isGroup))
                    // Pre-populate with existing suggestion
                    await MainActor.run {
                        let r = ScanResult(
                            id: username,
                            chatUsername: username,
                            displayName: username,
                            isGroup: isGroup,
                            suggestion: suggestion
                        )
                        results.append(r)
                    }
                }
            }

            let categorizer = AIWhitelistCategorizer(
                store: store,
                config: store.loadClassifierConfig()
            )

            await MainActor.run {
                total = candidates.count
            }

            for candidate in candidates {
                let input = AIWhitelistCategorizer.Input(
                    contactName: candidate.displayName,
                    isGroup: candidate.isGroup,
                    messages: []  // No messages available in scan context; AI infers from name/context
                )

                if let suggestion = await categorizer.categorize(input), suggestion.shouldWhitelist {
                    await MainActor.run {
                        let r = ScanResult(
                            id: candidate.username,
                            chatUsername: candidate.username,
                            displayName: candidate.displayName,
                            isGroup: candidate.isGroup,
                            suggestion: suggestion
                        )
                        // Avoid duplicates if already added from whitelistSuggestions
                        if !results.contains(where: { $0.id == r.id }) {
                            results.append(r)
                        }
                    }
                }

                await MainActor.run {
                    scanned += 1
                }
            }

            await MainActor.run {
                isScanning = false
            }
        }
    }
}
