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
    @State private var scanProgress: ContactRecommendationScanSource.Progress?
    @State private var scanTask: Task<Void, Never>?
    @State private var activeScanID: UUID?
    @State private var pendingRemoveDismissed: ScanDismissedEntry?

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
            VStack(alignment: .leading, spacing: 6) {
                Text("发现值得关注的对话").font(.headline)
                Text("扫描近期会话并把消息片段交给当前 AI 服务，建议需要持续关注的联系人和群聊。你接受建议后才会加入关注范围。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)

            // Pinned toolbar — always visible
            HStack {
                Button(action: { isScanning ? cancelScan() : startScan() }) {
                    HStack(spacing: 6) {
                        if isScanning {
                            ProgressView().controlSize(.small).scaleEffect(0.8)
                        } else {
                            Image(systemName: "sparkles").font(.system(size: 12))
                        }
                        Text(isScanning ? "停止扫描" : "开始扫描")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

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

            if isScanning, let scanProgress {
                HStack(spacing: 8) {
                    ProgressView(value: Double(scanProgress.completed), total: Double(max(scanProgress.total, 1)))
                        .frame(maxWidth: 180)
                    Text("读取消息 \(scanProgress.completed)/\(scanProgress.total)")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    if scanProgress.failed > 0 {
                        Text("不可读 \(scanProgress.failed)")
                            .font(.system(size: 11)).foregroundColor(.orange)
                    }
                }
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
        .onDisappear { cancelScan() }
        .alert("删除这条忽略记录？", isPresented: Binding(
            get: { pendingRemoveDismissed != nil },
            set: { if !$0 { pendingRemoveDismissed = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let entry = pendingRemoveDismissed {
                    pendingRemoveDismissed = nil
                    removeDismissed(entry)
                }
            }
            Button("取消", role: .cancel) { pendingRemoveDismissed = nil }
        } message: {
            Text("删除后该联系人可能重新出现在以后的扫描建议中。")
        }
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
            Button("添加关注") { acceptDismissed(entry) }
                .buttonStyle(.borderedProminent).controlSize(.mini)
            Button("删除", role: .destructive) { pendingRemoveDismissed = entry }
                .buttonStyle(.bordered).controlSize(.mini)
                .foregroundStyle(.red)
                .tint(.red)
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
            setStatus("已添加关注：\(displayName(for: item.username, fallback: item.displayName))")
            print("[WCHUD] AI scan: accepted \(item.username)")
        } catch {
            setStatus("添加关注失败：\(displayName(for: item.username, fallback: item.displayName))", isError: true)
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
            setStatus("已从忽略列表添加关注：\(displayName(for: entry.username, fallback: entry.displayName))")
            print("[WCHUD] AI scan: accepted dismissed \(entry.username)")
        } catch {
            setStatus("从忽略列表添加关注失败：\(displayName(for: entry.username, fallback: entry.displayName))", isError: true)
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
        let scanID = UUID()
        activeScanID = scanID
        isScanning = true
        results = []
        statusMessage = nil
        statusIsError = false
        scanProgress = ContactRecommendationScanSource.Progress(
            completed: 0, total: 0, succeeded: 0, failed: 0, empty: 0
        )

        let source = monitor.contactRecommendationScanSource()
        let excluded = Set(store.loadContacts(level: nil).map(\.username))
            .union(store.dismissedScanUsernames())

        scanTask = Task { @MainActor in
            let scan: ContactRecommendationScanSource.Result
            do {
                scan = try await source.scan(
                    limit: 500,
                    messageLimit: 5,
                    excluding: excluded,
                    progress: { progress in
                        guard activeScanID == scanID else { return }
                        scanProgress = progress
                    }
                )
            } catch {
                guard activeScanID == scanID else { return }
                activeScanID = nil
                scanTask = nil
                isScanning = false
                scanProgress = nil
                if error is CancellationError { return }
                setStatus("候选联系人读取失败。请检查微信连接和数据目录后重试。", isError: true)
                return
            }

            guard activeScanID == scanID, !Task.isCancelled else { return }
            guard !scan.candidates.isEmpty else {
                activeScanID = nil
                scanTask = nil
                isScanning = false
                scanProgress = nil
                setStatus("没有可扫描的候选联系人。请先同步微信并添加或发现联系人。")
                return
            }

            let batchItems = scan.messageBundles.map { bundle in
                AIWhitelistCategorizer.BatchItem(
                    index: bundle.candidateIndex + 1,
                    contactName: bundle.candidate.displayName,
                    isGroup: bundle.candidate.isGroup,
                    recentCount: bundle.candidate.recentCount,
                    messages: bundle.messages.map { (sender: $0.sender, body: $0.body) }
                )
            }

            let categorizer = AIWhitelistCategorizer(store: store, aiService: AIService(config: store.loadAIConfig()))
            var allResults: [AIWhitelistCategorizer.BatchResult] = []
            var failedChunks = 0

            let chunks = stride(from: 0, to: batchItems.count, by: 15).map {
                Array(batchItems[$0..<min($0 + 15, batchItems.count)])
            }
            for chunk in chunks {
                guard !Task.isCancelled else { return }
                let reindexed = chunk.enumerated().map { i, item in
                    AIWhitelistCategorizer.BatchItem(
                        index: i + 1, contactName: item.contactName, isGroup: item.isGroup,
                        recentCount: item.recentCount, messages: item.messages
                    )
                }
                let outcome = await categorizer.categorizeBatchWithStatus(reindexed)
                guard !Task.isCancelled else { return }
                failedChunks += outcome.failedChunks
                for br in outcome.results {
                    let idx = br.index - 1
                    guard idx >= 0, idx < chunk.count else { continue }
                    allResults.append(AIWhitelistCategorizer.BatchResult(
                        index: chunk[idx].index, category: br.category,
                        shouldWhitelist: br.shouldWhitelist, reason: br.reason
                    ))
                }
            }

            guard activeScanID == scanID, !Task.isCancelled else { return }
            for br in allResults {
                let candIdx = br.index - 1
                guard candIdx >= 0, candIdx < scan.candidates.count else { continue }
                let c = scan.candidates[candIdx]
                results.append(ScanResultItem(
                    id: c.username, username: c.username, displayName: c.displayName,
                    isGroup: c.isGroup, recentCount: c.recentCount,
                    category: br.category, shouldWhitelist: br.shouldWhitelist, reason: br.reason
                ))
            }
            isScanning = false
            scanProgress = nil
            scanTask = nil
            activeScanID = nil

            if scan.failures.count > 0 && allResults.isEmpty {
                setStatus("消息读取失败：\(scan.failures.count) 个候选无法读取，未生成推荐。请检查微信数据目录后重试。", isError: true)
            } else if scan.failures.count > 0 && failedChunks > 0 {
                setStatus("部分消息不可读：\(scan.failures.count) 个候选失败；另有 \(failedChunks) 个 AI 批次失败，已显示 \(allResults.count) 条结果。", isError: true)
            } else if scan.failures.count > 0 {
                setStatus("部分消息不可读：\(scan.failures.count) 个候选失败，已显示 \(allResults.count) 条结果。", isError: true)
            } else if batchItems.isEmpty {
                setStatus("找到 \(scan.candidates.count) 个候选联系人，但没有可分析的最近消息。", isError: false)
            } else if failedChunks > 0 && allResults.isEmpty {
                setStatus("AI 推荐失败：\(failedChunks) 个批次没有返回可用结果，请检查 AI 连接后重试。", isError: true)
            } else if failedChunks > 0 {
                setStatus("部分 AI 推荐失败：\(failedChunks) 个批次失败，已显示其余批次的 \(allResults.count) 条结果。", isError: true)
            } else if allResults.isEmpty {
                setStatus("扫描完成，没有新的建议。")
            } else if scan.emptyMessageCount > 0 {
                setStatus("扫描完成，已显示 \(allResults.count) 条建议；另有 \(scan.emptyMessageCount) 个候选没有最近消息。")
            } else {
                setStatus("扫描完成，已生成 \(allResults.count) 条建议。")
            }
        }
    }

    private func cancelScan() {
        guard isScanning || scanTask != nil else { return }
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
        if isScanning {
            isScanning = false
            scanProgress = nil
            setStatus("扫描已停止。")
        }
    }
}
