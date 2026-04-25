import Foundation
import Combine

/// Top-level orchestrator (Spec §6.2, §6.4, §6.5). Steps:
///   1. Resolve scope candidates from provider.
///   2. Insert review_runs row in 'running' state (so crash recovery can
///      reap it).
///   3. Group screen via GroupScreener (cached + AI fallback).
///   4. Concurrent per-chat analysis via TaskGroup (max 4 concurrent,
///      total job timeout 30 min).
///   5. Pre-dedupe carry-forward — collect candidates BEFORE writing,
///      let ReviewTodoManager dedupe, then insert survivors.
///   6. Synthesize summary.
///   7. Detect red banners.
///   8. Finalize run with status (completed / partial / failed).
///
/// Published `state` drives MenuBarController + UI.
@MainActor
final class RetrospectiveJob: ObservableObject {

    enum State: Sendable, Equatable {
        case idle
        case resolvingScope
        case screeningGroups
        case analyzingChats(progress: Int, total: Int)
        case synthesizingSummary
        case detectingRedBanner
        case completed(runID: Int)
        case failed(String)
        case partial(runID: Int, failedChats: [String])
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastRedBanners: [RedBannerCandidate] = []

    private let store: HUDStore
    private let aiService: any AIServiceProtocol
    private let scopeCandidatesProvider: any ScopeCandidatesProvider
    private let messageQuery: any MessageQuery
    private var config: RetrospectiveConfig
    private var currentTask: Task<Void, Never>?

    init(
        store: HUDStore,
        aiService: any AIServiceProtocol,
        scopeCandidatesProvider: any ScopeCandidatesProvider,
        messageQuery: any MessageQuery,
        config: RetrospectiveConfig = .default
    ) {
        self.store = store
        self.aiService = aiService
        self.scopeCandidatesProvider = scopeCandidatesProvider
        self.messageQuery = messageQuery
        self.config = config
    }

    /// Signals the running pipeline to stop. The running task observes
    /// `Task.isCancelled` at major boundaries; on observation it
    /// finalizes the in-flight `review_runs` row as `.failed` so it
    /// doesn't sit in 'running' state until reapStaleRuns (35 min) fires.
    /// Don't nil `currentTask` here — let the task itself drive the
    /// state transitions cleanly to `.failed` and then become quiescent.
    func cancel() {
        currentTask?.cancel()
    }

    func run(mode: ScopeMode, myUsername: String, myDisplayName: String) {
        // Reap any prior orphaned 'running' rows from a previous cancel
        // before starting a new run, so latestCompletedRun() doesn't
        // see polluted state.
        _ = store.reapStaleRuns(olderThanSeconds: 0)

        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.runInternal(mode: mode, myUsername: myUsername, myDisplayName: myDisplayName)
        }
    }

    /// Helper: finalize as failed + state = .failed, then return true if
    /// the caller should bail. Called at every major checkpoint.
    private func bailIfCancelled(runID: Int?, reason: String) -> Bool {
        guard Task.isCancelled else { return false }
        if let runID {
            store.finalizeReviewRun(
                runID: runID, status: .failed,
                summaryTop3: [], summaryRisk: nil, summaryMissed: nil,
                msgCount: 0, failedChats: ["__cancelled__"]
            )
        }
        state = .failed("cancelled: \(reason)")
        return true
    }

    private func runInternal(mode: ScopeMode, myUsername: String, myDisplayName: String) async {
        state = .resolvingScope
        if bailIfCancelled(runID: nil, reason: "before scope") { return }
        let dateRange = ScopeResolver.range(mode)
        let allCandidates = await scopeCandidatesProvider.candidates(in: dateRange)
        let filtered = ScopeResolver.filter(candidates: allCandidates).prefix(config.maxChatsPerRun)
        let chatsToAnalyze = Array(filtered)
        if bailIfCancelled(runID: nil, reason: "after scope") { return }

        guard let runID = store.insertReviewRun(
            rangeStart: dateRange.start,
            rangeEnd: dateRange.end,
            chatCount: chatsToAnalyze.count
        ) else {
            state = .failed("Could not create run row")
            return
        }

        // Group screen
        state = .screeningGroups
        let dataLedger = DataLedger(store: store)
        let screener = GroupScreener(store: store, aiService: aiService, dataLedger: dataLedger)
        let samples = await scopeCandidatesProvider.sampleMessages(
            for: chatsToAnalyze.map(\.chatUsername), in: dateRange, limit: 20
        )
        let screen = await screener.screen(candidates: chatsToAnalyze, samples: samples)
        if bailIfCancelled(runID: runID, reason: "after screen") { return }
        let included = screen.included

        // Capture local Sendable references so TaskGroup closures don't capture self.
        state = .analyzingChats(progress: 0, total: included.count)
        let redactor = Redactor()
        let analyzer = RetrospectiveAnalyzer(
            store: store, aiService: aiService,
            redactor: redactor, dataLedger: dataLedger
        )
        let provider = scopeCandidatesProvider
        let perChatLimit = config.maxMessagesPerChat
        let maxConcurrent = config.maxConcurrentChats
        let totalDeadline = Date().addingTimeInterval(config.totalTimeoutSeconds)

        struct ChatOutcome: Sendable {
            let chat: ScopeCandidate
            let result: Result<RetrospectiveAnalyzer.AnalysisResult, AnalyzerErrorBox>
        }
        struct AnalyzerErrorBox: Sendable, Error {
            let underlying: String
        }

        var collected: [ChatOutcome] = []
        var failed: [String] = []

        let analysisTask = Task<Void, Never> { @MainActor in
            await withTaskGroup(of: ChatOutcome.self) { group in
                var iterator = included.makeIterator()
                var completedCount = 0

                @Sendable func enqueue(_ chat: ScopeCandidate) {
                    group.addTask {
                        let messages = await provider.messages(
                            for: chat.chatUsername, in: dateRange, limit: perChatLimit
                        )
                        let relation = await provider.relation(for: chat.chatUsername)
                        do {
                            let result = try await analyzer.analyze(
                                chat: chat, relation: relation, messages: messages,
                                myUsername: myUsername, myDisplayName: myDisplayName, runID: runID
                            )
                            return ChatOutcome(chat: chat, result: .success(result))
                        } catch {
                            return ChatOutcome(chat: chat,
                                               result: .failure(AnalyzerErrorBox(underlying: "\(error)")))
                        }
                    }
                }

                for _ in 0..<min(maxConcurrent, included.count) {
                    if let next = iterator.next() { enqueue(next) }
                }

                for await outcome in group {
                    completedCount += 1
                    collected.append(outcome)
                    if case .failure = outcome.result {
                        failed.append(outcome.chat.chatName)
                    }
                    self.store.updateReviewRunProgress(runID: runID, completedChats: completedCount)
                    self.state = .analyzingChats(progress: completedCount, total: included.count)
                    if let next = iterator.next() { enqueue(next) }
                }
            }
        }

        // Race against total timeout (Spec §6.4: 30 min cap)
        let deadlineTask = Task<Void, Never> {
            let nanos = UInt64(max(0, totalDeadline.timeIntervalSinceNow) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            analysisTask.cancel()
        }

        await analysisTask.value
        deadlineTask.cancel()
        if bailIfCancelled(runID: runID, reason: "during analysis") { return }

        // If the analysis loop terminated early without collecting all
        // outcomes (e.g. timeout / external cancel), treat the missing
        // chats as failed so finalStatus reflects reality.
        let collectedChats = Set(collected.map(\.chat.chatUsername))
        for chat in included where !collectedChats.contains(chat.chatUsername) {
            failed.append(chat.chatName)
        }

        // Pre-dedupe carry-forward (BEFORE inserting into DB)
        var newHighlights: [ReviewHighlight] = []
        var newTodoCandidates: [ReviewTodo] = []
        var totalMsgCount = 0
        for outcome in collected {
            if case .success(let analysis) = outcome.result {
                newHighlights.append(contentsOf: analysis.highlights)
                newTodoCandidates.append(contentsOf: analysis.todos)
                totalMsgCount += analysis.highlights.count + analysis.todos.count
            }
        }

        let prevRun = store.latestCompletedRun()
        let manager = ReviewTodoManager(store: store)
        let todosToInsert: [ReviewTodo]
        if let prev = prevRun {
            todosToInsert = await manager.carryForward(
                prevRunID: prev.id, newRunID: runID, newCandidates: newTodoCandidates
            )
        } else {
            todosToInsert = newTodoCandidates
        }

        // Insert highlights + survivor todos
        for h in newHighlights { store.insertReviewHighlight(h) }
        for t in todosToInsert { store.insertReviewTodo(t) }

        // Synthesize summary
        state = .synthesizingSummary
        if bailIfCancelled(runID: runID, reason: "before synth") { return }
        let synth = SummarySynthesizer(store: store, aiService: aiService, dataLedger: dataLedger)
        let summary = await synth.synthesize(runID: runID)

        // Red banners
        state = .detectingRedBanner
        if bailIfCancelled(runID: runID, reason: "before banners") { return }
        let detector = RedBannerDetector(store: store, messageQuery: messageQuery)
        let banners = await detector.detect()
        lastRedBanners = banners

        // Finalize
        let finalStatus: ReviewRunStatus = {
            if included.isEmpty { return .completed }
            if failed.isEmpty { return .completed }
            if failed.count == included.count { return .failed }
            return .partial
        }()
        store.finalizeReviewRun(
            runID: runID, status: finalStatus,
            summaryTop3: summary.top3,
            summaryRisk: summary.risk,
            summaryMissed: summary.missed,
            msgCount: totalMsgCount,
            failedChats: failed
        )

        state = (finalStatus == .partial)
            ? .partial(runID: runID, failedChats: failed)
            : .completed(runID: runID)
    }
}
