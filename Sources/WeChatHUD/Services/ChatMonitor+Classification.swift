import Foundation

extension ChatMonitor {
    /// One worker owns queue consumption. The source snapshot was persisted before
    /// the scan cursor advanced, so failures can be retried after restart.
    func drainClassificationQueue() {
        classificationPendingCount = store.classificationQueueCount()
        guard classificationWorker == nil, classificationPendingCount > 0 else { return }
        classificationProcessing = true
        classificationWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.classificationWorker = nil
                self.classificationProcessing = false
                self.classificationPendingCount = self.store.classificationQueueCount()
            }
            let readerActor = WeChatReaderActor(self.reader)
            guard await self.aiService.isConfigured(), !(await readerActor.hasAccountSwitched()) else { return }
            while !Task.isCancelled {
                let messages = self.store.pendingClassificationMessages(limit: 10)
                guard !messages.isEmpty else { break }
                let completed = await self.classifyPendingMessages(messages.map { ($0.chatUsername, $0) })
                for message in messages {
                    do {
                        if completed.contains(message.id) {
                            try self.store.completeClassificationMessage(id: message.id)
                        } else {
                            try self.store.deferClassificationMessage(id: message.id)
                        }
                    } catch {
                        // A failed ACK must leave the job recoverable; stop rather
                        // than repeatedly calling the model against a broken store.
                        return
                    }
                }
                self.classificationPendingCount = self.store.classificationQueueCount()
                guard await self.aiService.isConfigured(), !(await readerActor.hasAccountSwitched()) else { break }
            }
        }
    }

    /// Returns only successfully handled source IDs. A non-ask is success, while
    /// an AI or persistence failure stays unacknowledged for the queue to retry.
    func classifyPendingMessages(_ items: [(chatUsername: String, msg: MessageInfo)]) async -> Set<String> {
        var completed: Set<String> = []
        let readerActor = WeChatReaderActor(reader)
        let myUsername = await readerActor.myUsername()
        let myDisplayName = await readerActor.displayName(for: myUsername)
        let selfNames = await readerActor.mySelfNames()
        guard !myUsername.isEmpty, !(await readerActor.hasAccountSwitched()) else { return completed }
        // One snapshot for the whole drain: the admission rules are consulted
        // per item, and re-reading them per message would put several queries on
        // a path that runs for every queued message.
        let admissionRules = AdmissionRules.load(store: store)
        for item in items {
            guard !Task.isCancelled, !(await readerActor.hasAccountSwitched()) else { break }
            let msg = item.msg
            // Recheck scope at consumption time: the user may have removed a chat
            // or ignored a sender while this item was backing off.
            guard item.chatUsername == msg.chatUsername,
                  !MessageHelpers.isFromSelf(msg, chatUsername: msg.chatUsername, myUsername: myUsername,
                                             myDisplayName: myDisplayName, mySelfNames: selfNames) else {
                completed.insert(msg.id)
                continue
            }
            switch scopeVerdict(for: msg, in: item.chatUsername, store: store, rules: admissionRules) {
            case .retire:
                completed.insert(msg.id)
                continue
            case .retry:
                // Back off and keep the row; see `scopeVerdict`.
                try? store.deferClassificationMessage(id: msg.id)
                continue
            case .proceed:
                break
            }
            let isAt = MessageHelpers.isAtMe(
                msg.text, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: selfNames
            )
            guard admissionRules.decide(
                chatUsername: msg.chatUsername,
                isGroup: MessageHelpers.isGroupChat(msg.chatUsername),
                senderUsername: msg.senderUsername,
                senderName: msg.senderName,
                isAtMention: isAt
            ).isAdmitted else {
                switch Self.dispositionForUnadmitted(
                    followingUnreadable: admissionRules.scopeUnreadable
                ) {
                case .retire: completed.insert(msg.id)
                case .retry: try? store.deferClassificationMessage(id: msg.id)
                }
                continue
            }
            // A message with no readable text left after sanitizing — a sticker,
            // an image, a system row — has nothing for the classifier to read.
            // It used to arrive as an empty `{message_body}`, which left the
            // model guessing an ask/no-ask from the two names around it while
            // the prompt's own few-shot example still taught it the "[图片]"
            // literal that could no longer reach it.
            guard !AIService.sanitizeForAI(msg.text).isEmpty else {
                completed.insert(msg.id)
                continue
            }
            let input = ClassifierInput(msgUID: msg.id, text: msg.text, senderName: msg.senderName,
                                        chatName: msg.chatName, isGroup: MessageHelpers.isGroupChat(msg.chatUsername))
            // SQL bounds precede LIMIT: an old queued message gets its own prior
            // context, never whatever happens to be latest today. Exclude the whole
            // target second to avoid incorporating later same-second messages.
            let contextMessages = (try? await readerActor.getMessages(
                chatUsername: msg.chatUsername, limit: 12, afterCursor: nil,
                startTime: msg.createTime - 86400, endTime: msg.createTime
            )) ?? []
            let context = contextMessages.reversed().map {
                "\(AIService.oneLine($0.senderName)): \(AIService.oneLine(AIService.sanitizeForAI($0.text)))"
            }.joined(separator: "\n")
            var knownOtherNames = Set(store.loadContacts()
                .filter { $0.username != myUsername }
                .flatMap { [$0.username, $0.displayName] }
                .filter { !$0.isEmpty })
            for preceding in contextMessages where !MessageHelpers.isFromSelf(
                preceding, chatUsername: msg.chatUsername, myUsername: myUsername,
                myDisplayName: myDisplayName, mySelfNames: selfNames
            ) {
                knownOtherNames.formUnion([preceding.senderUsername, preceding.senderName].filter { !$0.isEmpty })
            }
            let recipientContext = AIClassifier.RecipientContext(
                myUsername: myUsername, myDisplayName: myDisplayName,
                mySelfNames: selfNames, knownOtherNames: knownOtherNames,
                precedingMessages: context
            )
            guard let result = await aiClassifier.classify(message: input, recipientContext: recipientContext) else { continue }
            guard !(await readerActor.hasAccountSwitched()) else { break }
            guard result.isAsk, result.confidence >= 0.5 else {
                completed.insert(msg.id)
                continue
            }
            // Scope can change while the provider is answering as well.
            switch scopeVerdict(for: msg, in: msg.chatUsername, store: store, rules: admissionRules) {
            case .retire:
                completed.insert(msg.id)
                continue
            case .retry:
                try? store.deferClassificationMessage(id: msg.id)
                continue
            case .proceed:
                break
            }
            let contact = store.getContact(username: msg.senderUsername)
            let messageDate = Date(timeIntervalSince1970: Double(msg.createTime))
            let deadline = result.deadlineRelative.flatMap { MessageHelpers.resolveDeadline($0, relativeTo: messageDate) }
            let ask = PendingAsk(
                id: 0, msgUID: msg.id, chatUsername: msg.chatUsername, chatName: msg.chatName,
                senderName: msg.senderName, rawText: msg.text, summary: result.summary,
                askType: result.type, deadlineAt: deadline, confidence: result.confidence,
                bucket: result.confidence >= 0.85 ? .main : .review, status: .pending,
                promptVersion: result.promptVersion, createdAt: messageDate, updatedAt: Date(),
                senderLevel: contact?.attentionLevel, senderRole: contact?.role, urgency: nil
            )
            do {
                try store.upsertPendingAsk(ask)
                completed.insert(msg.id)
            } catch {
                // The durable queue still owns this source message.
            }
        }
        return completed
    }

    /// Out-of-scope re-check that can tell 「这条不在范围内，把队列行删掉」 apart
    /// from 「读不到，等会儿再试」.
    ///
    /// `store.isWhitelisted` answers `false` for both, and the caller retired the
    /// queue row on `false` — so one BUSY or I/O error erased the only record
    /// that this message needed analysis: no 待办, no badge, no 未回, and nothing
    /// in the log to explain the gap. Deferring reuses the queue's own
    /// attempts/backoff rather than inventing a second one.
    enum ScopeVerdict: Equatable { case proceed, retire, retry }

    /// What to do with a message the admission rules rejected.
    ///
    /// The bulk follow-list read (`getWhitelist`) answers `[]` both for 「没关注
    /// 任何人」 and for 「这次读不到」, `AdmissionPolicy.decide` turns that into
    /// 「没关注」, and this branch used to delete the queue row — so a single BUSY
    /// during `AdmissionRules.load` erased a whole batch of pending analysis
    /// rather than one row. Same conflation as ``scopeVerdict(whitelist:muted:)``,
    /// one level up, and destructive in the same direction.
    enum UnadmittedDisposition: Equatable { case retire, retry }

    nonisolated static func dispositionForUnadmitted(
        followingUnreadable: Bool
    ) -> UnadmittedDisposition {
        followingUnreadable ? .retry : .retire
    }

    /// The mapping itself, so a test can drive all three arms: the caller's
    /// job is only to hand it a real read and honour the answer.
    nonisolated static func scopeVerdict(
        whitelist: HUDStore.WhitelistRead, muted: Bool
    ) -> ScopeVerdict {
        switch whitelist {
        case .unreadable: return .retry
        case .unfollowed: return .retire
        case .followed: break
        }
        return muted ? .retire : .proceed
    }

    private func scopeVerdict(
        for msg: MessageInfo,
        in chatUsername: String,
        store: HUDStore,
        rules: AdmissionRules
    ) -> ScopeVerdict {
        Self.scopeVerdict(
            whitelist: store.whitelistRead(chatUsername),
            muted: rules.isMuted(
                chatUsername: chatUsername,
                senderUsername: msg.senderUsername,
                senderName: msg.senderName
            )
        )
    }

}
