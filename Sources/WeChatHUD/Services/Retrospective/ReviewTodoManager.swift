import Foundation

/// Owns todo state-machine transitions + cross-run carry-forward
/// (Spec §6.2 step 7, §3.3). All methods delegate to HUDStore;
/// this actor exists to provide a single async surface for orchestrators
/// (RetrospectiveJob) and UI ViewModels.
actor ReviewTodoManager {
    private let store: HUDStore

    init(store: HUDStore) {
        self.store = store
    }

    // MARK: - Carry-forward (Spec §6.2 step 7)

    /// Returns the candidates that survived dedupe and should be inserted as new
    /// `review_todos` rows. Side effect: bumps surviving prev-run pending todos
    /// to `newRunID` (and prev-run pending todos that did NOT match any new
    /// candidate are also bumped — they're still active).
    ///
    /// Dedupe match conditions (any one triggers — Spec §6.2 step 7b):
    ///  1. `source_msg_ids` set overlap
    ///  2. Same `source_chat_username` AND content Jaccard > 0.6
    ///  3. Same `source_chat_username` AND ≥1 shared `involved` AND same deadline day
    func carryForward(
        prevRunID: Int,
        newRunID: Int,
        newCandidates: [ReviewTodo]
    ) -> [ReviewTodo] {
        let prevPending = store.todos(for: prevRunID, statuses: [.pending])
        var deduped = newCandidates

        for prev in prevPending {
            if let matchIdx = deduped.firstIndex(where: { ReviewTodoManager.matches(prev: prev, cand: $0) }) {
                deduped.remove(at: matchIdx)
                store.bumpTodoCarry(todoID: prev.id, newRunID: newRunID)
            } else {
                // Prev still pending but not re-extracted in this run.
                // Carry forward anyway so the user can act on it.
                store.bumpTodoCarry(todoID: prev.id, newRunID: newRunID)
            }
        }
        return deduped
    }

    static func matches(prev: ReviewTodo, cand: ReviewTodo) -> Bool {
        // 1. msg_ids overlap
        let prevSet = Set(prev.sourceMsgIDs)
        let candSet = Set(cand.sourceMsgIDs)
        if !prevSet.isDisjoint(with: candSet) { return true }

        // 2. same chat + Jaccard > 0.6
        if prev.sourceChatUsername == cand.sourceChatUsername {
            if TextSimilarity.jaccardCJK(prev.content, cand.content) > 0.6 {
                return true
            }
        }

        // 3. same chat + shared involved + same deadline day
        if prev.sourceChatUsername == cand.sourceChatUsername,
           let pd = prev.deadline, let cd = cand.deadline {
            let sharedInvolved = !Set(prev.involved).intersection(cand.involved).isEmpty
            let sameDeadlineDay = Calendar.current.isDate(pd, inSameDayAs: cd)
            if sharedInvolved && sameDeadlineDay { return true }
        }

        return false
    }

    /// Surfaces todos that have been carried forward ≥ N runs without
    /// the user touching them — UI can render an "已延续 N 周 [建议归档?]"
    /// affordance instead of the default "不是我的事" button (Spec §4.2).
    /// Does NOT auto-archive (user confirmation required).
    func suggestArchiveStaleTodos(olderThanWeeks: Int = 4) -> [ReviewTodo] {
        store.pendingTodos().filter { $0.carryCount >= olderThanWeeks }
    }

    // MARK: - Four-state operations (Spec §3.3)

    func markCompleted(todoID: Int) {
        store.updateTodoStatus(todoID: todoID, status: .completed, completedAt: Date())
    }

    func snooze(todoID: Int, until: Date) {
        store.updateTodoStatus(todoID: todoID, status: .snoozed, snoozedTo: until)
    }

    func markNotMine(todoID: Int) {
        store.updateTodoStatus(todoID: todoID, status: .notMine)
    }

    func delegate(todoID: Int, to: String) {
        store.updateTodoStatus(todoID: todoID, status: .delegated, delegatedTo: to)
    }

    func archive(todoID: Int) {
        store.updateTodoStatus(todoID: todoID, status: .archived)
    }
}
