import SwiftUI

struct WhitelistScanView: View {
   @EnvironmentObject private var store: HUDStore
   @EnvironmentObject var monitor: ChatMonitor

    @EnvironmentObject var panelState: PanelState

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
   @State private var isRemovingDismissed = false
    @State private var didCompleteScan = false

   private enum ScanWrite: Equatable {
        case accept(String)
        case dismiss(String)
        case acceptDismissed(String)
        case acceptAll
        case dismissAll

        var help: String {
            switch self {
            case .accept, .acceptDismissed, .acceptAll: return "正在添加关注"
            case .dismiss, .dismissAll: return "正在忽略建议"
            }
        }
    }

    @State private var busyWrite: ScanWrite?

    private var isWriting: Bool { busyWrite != nil }

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
                .tint(CompanionPalette.accent)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Spacer()

                if !pendingResults.isEmpty {
                    Text("\(pendingResults.count) 条待处理")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Button {
                        commit(.acceptAll) { acceptAll() }
                    } label: {
                        Text(busyWrite == .acceptAll ? "正在添加…" : "全部接受")
                    }
                        .tint(CompanionPalette.accent)
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(isWriting)
                        .help(isWriting ? (busyWrite?.help ?? "") : "")
                        .accessibilityHint(isWriting ? (busyWrite?.help ?? "") : "")
                    Button {
                        commit(.dismissAll) { dismissAll() }
                    } label: {
                        Text(busyWrite == .dismissAll ? "正在忽略…" : "全部忽略")
                    }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(isWriting)
                        .help(isWriting ? (busyWrite?.help ?? "") : "")
                        .accessibilityHint(isWriting ? (busyWrite?.help ?? "") : "")
                }
            }
            .padding(.bottom, 12)

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(statusIsError ? .red : .secondary)
                    .padding(.bottom, 8)
                    .transition(.companionStatusReveal)
            }

            if isScanning, let scanProgress {
                HStack(spacing: 8) {
                    ProgressView(value: Double(scanProgress.completed), total: Double(max(scanProgress.total, 1)))
                        .frame(maxWidth: 180)
                    Text("正在读取会话 \(scanProgress.completed)/\(scanProgress.total)")
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

                    if results.isEmpty && groupedResults.isEmpty && !isScanning && dismissed.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(didCompleteScan
                                 ? "这一轮没有待处理的建议。已关注的人仍在「关注谁」里。"
                                 : "还没有扫描建议。开始扫描后，近期会话会出现在这里。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            if didCompleteScan {
                                Button("查看已关注") {
                                    NotificationCenter.default.post(name: .hudSwitchTab, object: "contacts")
                                }
                                .buttonStyle(CompanionPressStyle())
                                .foregroundStyle(CompanionPalette.jadeInk)
                                .accessibilityLabel("去关注谁查看已关注的人")
                            } else {
                                Button("开始扫描") { startScan() }
                                    .buttonStyle(CompanionPressStyle())
                                    .foregroundStyle(CompanionPalette.jadeInk)
                                    .accessibilityLabel("开始扫描值得关注的对话")
                            }
                        }
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
        .companionAnimation(CompanionMotion.ease(), value: statusMessage)
        .companionDialogBackdrop(pendingRemoveDismissed != nil) {
            if let entry = pendingRemoveDismissed {
                CompanionDialog(title: "删除这条忽略记录？", onClose: { if !isRemovingDismissed { pendingRemoveDismissed = nil } }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("删除后该联系人可能重新出现在以后的扫描建议中。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if statusIsError, let statusMessage {
                            Text(statusMessage)
                                .font(.system(size: 13))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.companionStatusReveal)
                        }
                        HStack {
                            Spacer()
                            Button("取消") { pendingRemoveDismissed = nil }
                                .companionBusyHold(isRemovingDismissed, "正在删除这条忽略记录")
                            Button(role: .destructive) {
                                guard !isRemovingDismissed else { return }
                                isRemovingDismissed = true
                                Task { @MainActor in
                                    let ok = removeDismissed(entry)
                                    isRemovingDismissed = false
                                    if ok { pendingRemoveDismissed = nil }
                                }
                            } label: {
                                Text(isRemovingDismissed ? "正在删除忽略记录…" : "删除")
                            }
                            .disabled(isRemovingDismissed)
                            .help(isRemovingDismissed ? "正在删除这条忽略记录" : "")
                            .accessibilityHint(isRemovingDismissed ? "正在删除这条忽略记录" : "")
                        }
                    }
                }
            }
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
                        Text("群").font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12)).cornerRadius(3)
                    }
                }
                HStack(spacing: 8) {
                    Text("\(item.recentCount) 条 / 45 天")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    Text(item.reason)
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button {
                commit(.accept(item.id)) { accept(item) }
            } label: {
                Text(busyWrite == .accept(item.id) ? "正在添加…" : "加入")
            }
                .tint(CompanionPalette.accent)
                .buttonStyle(.borderedProminent).controlSize(.mini)
                .disabled(isWriting)
                .help(isWriting ? (busyWrite?.help ?? "") : "")
                .accessibilityHint(isWriting ? (busyWrite?.help ?? "") : "")
            Button {
                commit(.dismiss(item.id)) { dismiss(item) }
            } label: {
                Text(busyWrite == .dismiss(item.id) ? "正在忽略…" : "忽略")
            }
                .buttonStyle(.bordered).controlSize(.mini)
                .disabled(isWriting)
                .help(isWriting ? (busyWrite?.help ?? "") : "")
                .accessibilityHint(isWriting ? (busyWrite?.help ?? "") : "")
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
            Button {
                commit(.acceptDismissed(entry.username)) { acceptDismissed(entry) }
            } label: {
                Text(busyWrite == .acceptDismissed(entry.username) ? "正在添加…" : "添加关注")
            }
                .tint(CompanionPalette.accent)
                .buttonStyle(.borderedProminent).controlSize(.mini)
                .disabled(isWriting)
                .help(isWriting ? (busyWrite?.help ?? "") : "")
                .accessibilityHint(isWriting ? (busyWrite?.help ?? "") : "")
            Button("删除", role: .destructive) { pendingRemoveDismissed = entry }
                .buttonStyle(.bordered).controlSize(.mini)
                .disabled(isWriting)
                .help(isWriting ? (busyWrite?.help ?? "") : "")
                .accessibilityHint(isWriting ? (busyWrite?.help ?? "") : "")
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
            panelState.returnToInsightIfResuming(
                item.username,
                receipt: "已添加关注：\(displayName(for: item.username, fallback: item.displayName))")
       } catch {
           setStatus("没能添加关注：\(displayName(for: item.username, fallback: item.displayName))。请重试。", isError: true)
       }
   }

    private func dismiss(_ item: ScanResultItem) {
        do {
            try store.dismissScanResult(username: item.username, displayName: item.displayName)
            results.removeAll { $0.id == item.id }
            loadDismissed()
            showDismissed = true
           setStatus("已忽略：\(displayName(for: item.username, fallback: item.displayName))")
       } catch {
           setStatus("没能忽略这条建议：\(displayName(for: item.username, fallback: item.displayName))。请重试。", isError: true)
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
                isGroup: MessageHelpers.isGroupChat(entry.username),
                category: .other,
                attentionLevel: .watch
            )
           try store.undismissScanResult(username: entry.username)
           loadDismissed()
          setStatus("已从忽略列表添加关注：\(displayName(for: entry.username, fallback: entry.displayName))")
            panelState.returnToInsightIfResuming(
                entry.username,
                receipt: "已从忽略列表添加关注：\(displayName(for: entry.username, fallback: entry.displayName))")
       } catch {
           setStatus("没能从忽略列表添加关注：\(displayName(for: entry.username, fallback: entry.displayName))。请重试。", isError: true)
       }
   }

    @discardableResult
    private func removeDismissed(_ entry: ScanDismissedEntry) -> Bool {
        do {
            try store.undismissScanResult(username: entry.username)
            loadDismissed()
           setStatus("已删除忽略记录：\(displayName(for: entry.username, fallback: entry.displayName))")
           return true
       } catch {
           setStatus("没能删除忽略记录：\(displayName(for: entry.username, fallback: entry.displayName))。请重试。", isError: true)
           return false
        }
    }

    private func loadDismissed() { dismissed = store.loadDismissedScanResults() }

    private func setStatus(_ message: String, isError: Bool = false) {
        statusMessage = message
        statusIsError = isError
    }

    private func commit(_ write: ScanWrite, _ work: @escaping () -> Void) {
        guard busyWrite == nil, !isRemovingDismissed else { return }
        busyWrite = write
        Task { @MainActor in
            defer { busyWrite = nil }
            work()
        }
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
        didCompleteScan = false
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
                didCompleteScan = true
               setStatus("没能读到近期会话。请确认微信已连接后再试一次。", isError: true)
               return
            }

            guard activeScanID == scanID, !Task.isCancelled else { return }
            guard !scan.candidates.isEmpty else {
                activeScanID = nil
                scanTask = nil
               isScanning = false
               scanProgress = nil
                didCompleteScan = true
               setStatus("现在没有可扫描的会话。连上微信后，近期聊天会出现在这里。")
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

            didCompleteScan = true

          if scan.failures.count > 0 && allResults.isEmpty {
                setStatus("有 \(scan.failures.count) 个会话读不到，这次没有推荐。请确认微信已连接后再试。", isError: true)
            } else if scan.failures.count > 0 && failedChunks > 0 {
                setStatus("有些会话读不完整，有些推荐没写出来。目前显示 \(allResults.count) 条，可再试一次。", isError: true)
            } else if scan.failures.count > 0 {
                setStatus("有 \(scan.failures.count) 个会话读不完整，目前显示 \(allResults.count) 条。可再试一次。", isError: true)
            } else if batchItems.isEmpty {
                setStatus("找到一些近期会话，但还没有可整理的消息。", isError: false)
            } else if failedChunks > 0 && allResults.isEmpty {
                setStatus("没能写出推荐。请到「AI 服务」看连接，再试一次。", isError: true)
            } else if failedChunks > 0 {
                setStatus("有些推荐没写出来，目前显示 \(allResults.count) 条。可再试一次。", isError: true)
            } else if allResults.isEmpty {
                setStatus("扫描完成，没有新的建议。")
            } else if scan.emptyMessageCount > 0 {
                setStatus("扫描完成，已显示 \(allResults.count) 条建议；另有一些会话还没有最近消息。")
            } else {
                setStatus("扫描完成，已列出 \(allResults.count) 条建议。")
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
