import SwiftUI

struct WhitelistScanView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject var monitor: ChatMonitor

    @State private var isScanning = false
    @State private var results: [ScanResultItem] = []
    @State private var dismissed: [ScanDismissedEntry] = []
    @State private var showDismissed = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    struct ScanResultItem: Identifiable {
        let id: String
        let username: String
        let displayName: String
        let isGroup: Bool
        let recentCount: Int
        let category: String
        let shouldWhitelist: Bool
        let reason: String
        var accepted: Bool = false
    }

    private var pendingResults: [ScanResultItem] {
        results.filter { !$0.accepted && $0.shouldWhitelist }
    }

    private var groupedResults: [(String, [ScanResultItem])] {
        let groups = Dictionary(grouping: pendingResults) { $0.category }
        return ["work", "life", "other"].compactMap { key in
            guard let items = groups[key], !items.isEmpty else { return nil }
            return (key, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned toolbar — always visible
            HStack {
                Button(action: startScan) {
                    HStack(spacing: 6) {
                        if isScanning {
                            ProgressView().controlSize(.small).scaleEffect(0.8)
                        } else {
                            Image(systemName: "sparkles").font(.system(size: 12))
                        }
                        Text(isScanning ? "扫描中…" : "开始扫描")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isScanning)

                Spacer()

                if !pendingResults.isEmpty {
                    Text("\(pendingResults.count) 条待处理")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Button("全部接受") { acceptAll() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("全部忽略") { dismissAll() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.bottom, 12)

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(statusIsError ? .red : .secondary)
                    .padding(.bottom, 8)
            }

            // Scrollable results
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !results.isEmpty && pendingResults.isEmpty && !isScanning {
                        Label("扫描完成，没有新的建议", systemImage: "checkmark.circle")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }

                    ForEach(groupedResults, id: \.0) { category, items in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Circle().fill(colorFor(category)).frame(width: 8, height: 8)
                                Text(labelFor(category))
                                    .font(.system(size: 12, weight: .semibold))
                                Text("(\(items.count))")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            VStack(spacing: 1) {
                                ForEach(items) { item in resultRow(item) }
                            }
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(8)
                        }
                    }

                    if !dismissed.isEmpty {
                        Divider()
                        DisclosureGroup(isExpanded: $showDismissed) {
                            VStack(spacing: 1) {
                                ForEach(dismissed) { entry in dismissedRow(entry) }
                            }
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(8)
                        } label: {
                            Text("已忽略 (\(dismissed.count))")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .onAppear { loadDismissed() }
    }

    // MARK: - Helpers

    private func labelFor(_ cat: String) -> String {
        switch cat { case "work": return "工作"; case "life": return "生活"; default: return "其他" }
    }

    private func colorFor(_ cat: String) -> Color {
        switch cat { case "work": return .blue; case "life": return .green; default: return .gray }
    }

    // MARK: - Rows

    private func resultRow(_ item: ScanResultItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if item.isGroup {
                        Text("群").font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12)).cornerRadius(3)
                    }
                }
                HStack(spacing: 8) {
                    Text("\(item.recentCount) 条/45天")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    Text(item.reason)
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button("加入") { accept(item) }
                .buttonStyle(.borderedProminent).controlSize(.mini)
            Button("忽略") { dismiss(item) }
                .buttonStyle(.bordered).controlSize(.mini)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func dismissedRow(_ entry: ScanDismissedEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName.isEmpty ? entry.username : entry.displayName)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("忽略于 \(entry.dismissedAt.formatted(.dateTime.month().day()))")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Button("加入白名单") { acceptDismissed(entry) }
                .buttonStyle(.borderedProminent).controlSize(.mini)
            Button("删除") { removeDismissed(entry) }
                .buttonStyle(.bordered).controlSize(.mini)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    // MARK: - Actions

    private func accept(_ item: ScanResultItem) {
        let cat: WhitelistCategory = item.category == "work" ? .work : item.category == "life" ? .life : .other
        do {
            try store.addToWhitelist(
                username: item.username,
                displayName: item.displayName,
                isGroup: item.isGroup,
                category: cat,
                attentionLevel: .watch
            )
            if let idx = results.firstIndex(where: { $0.id == item.id }) {
                results[idx].accepted = true
            }
            setStatus("已加入白名单：\(displayName(for: item.username, fallback: item.displayName))")
            print("[WCHUD] AI scan: accepted \(item.username)")
        } catch {
            setStatus("加入白名单失败：\(displayName(for: item.username, fallback: item.displayName))", isError: true)
            print("[WCHUD] AI scan: accept failed for \(item.username): \(error)")
        }
    }

    private func dismiss(_ item: ScanResultItem) {
        do {
            try store.dismissScanResult(username: item.username, displayName: item.displayName)
            results.removeAll { $0.id == item.id }
            loadDismissed()
            showDismissed = true
            setStatus("已忽略：\(displayName(for: item.username, fallback: item.displayName))")
            print("[WCHUD] AI scan: dismissed \(item.username)")
        } catch {
            setStatus("忽略失败：\(displayName(for: item.username, fallback: item.displayName))", isError: true)
            print("[WCHUD] AI scan: dismiss failed for \(item.username): \(error)")
        }
    }

    private func acceptAll() {
        let items = pendingResults
        for item in items { accept(item) }
    }

    private func dismissAll() {
        let items = pendingResults
        for item in items { dismiss(item) }
    }

    private func acceptDismissed(_ entry: ScanDismissedEntry) {
        do {
            try store.addToWhitelist(
                username: entry.username,
                displayName: entry.displayName,
                isGroup: entry.username.contains("@chatroom"),
                category: .other,
                attentionLevel: .watch
            )
            try store.undismissScanResult(username: entry.username)
            loadDismissed()
            setStatus("已从忽略列表加入白名单：\(displayName(for: entry.username, fallback: entry.displayName))")
            print("[WCHUD] AI scan: accepted dismissed \(entry.username)")
        } catch {
            setStatus("从忽略列表加入白名单失败：\(displayName(for: entry.username, fallback: entry.displayName))", isError: true)
            print("[WCHUD] AI scan: accept dismissed failed for \(entry.username): \(error)")
        }
    }

    private func removeDismissed(_ entry: ScanDismissedEntry) {
        do {
            try store.undismissScanResult(username: entry.username)
            loadDismissed()
            setStatus("已删除忽略记录：\(displayName(for: entry.username, fallback: entry.displayName))")
            print("[WCHUD] AI scan: removed dismissed \(entry.username)")
        } catch {
            setStatus("删除忽略记录失败：\(displayName(for: entry.username, fallback: entry.displayName))", isError: true)
            print("[WCHUD] AI scan: remove dismissed failed for \(entry.username): \(error)")
        }
    }

    private func loadDismissed() { dismissed = store.loadDismissedScanResults() }

    private func setStatus(_ message: String, isError: Bool = false) {
        statusMessage = message
        statusIsError = isError
    }

    private func displayName(for username: String, fallback: String) -> String {
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? username : trimmed
    }

    // MARK: - Scan

    private func startScan() {
        guard !isScanning else { return }
        isScanning = true
        results = []

        Task {
            let candidates = monitor.scanCandidates(limit: 500)
            guard !candidates.isEmpty else {
                await MainActor.run { isScanning = false }
                return
            }

            var batchItems: [AIWhitelistCategorizer.BatchItem] = []
            for (i, c) in candidates.enumerated() {
                let msgs = monitor.recentMessages(chatUsername: c.username, limit: 5)
                guard !msgs.isEmpty else { continue }
                batchItems.append(AIWhitelistCategorizer.BatchItem(
                    index: i + 1, contactName: c.displayName, isGroup: c.isGroup,
                    recentCount: c.recentCount, messages: msgs
                ))
            }

            let categorizer = AIWhitelistCategorizer(store: store, aiService: AIService(config: store.loadAIConfig()))
            var allResults: [AIWhitelistCategorizer.BatchResult] = []

            let chunks = stride(from: 0, to: batchItems.count, by: 15).map {
                Array(batchItems[$0..<min($0 + 15, batchItems.count)])
            }
            for chunk in chunks {
                let reindexed = chunk.enumerated().map { i, item in
                    AIWhitelistCategorizer.BatchItem(
                        index: i + 1, contactName: item.contactName, isGroup: item.isGroup,
                        recentCount: item.recentCount, messages: item.messages
                    )
                }
                let batchResults = await categorizer.categorizeBatch(reindexed)
                for br in batchResults {
                    let idx = br.index - 1
                    guard idx >= 0, idx < chunk.count else { continue }
                    allResults.append(AIWhitelistCategorizer.BatchResult(
                        index: chunk[idx].index, category: br.category,
                        shouldWhitelist: br.shouldWhitelist, reason: br.reason
                    ))
                }
            }

            let itemByIndex = Dictionary(uniqueKeysWithValues: batchItems.map { ($0.index, $0) })

            await MainActor.run {
                for br in allResults {
                    guard let _ = itemByIndex[br.index] else { continue }
                    let candIdx = br.index - 1
                    guard candIdx >= 0, candIdx < candidates.count else { continue }
                    let c = candidates[candIdx]
                    results.append(ScanResultItem(
                        id: c.username, username: c.username, displayName: c.displayName,
                        isGroup: c.isGroup, recentCount: c.recentCount,
                        category: br.category, shouldWhitelist: br.shouldWhitelist, reason: br.reason
                    ))
                }
                isScanning = false
            }
        }
    }
}
