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
            guard await self.aiService.isConfigured(), !self.reader.hasAccountSwitched() else { return }
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
                guard await self.aiService.isConfigured(), !self.reader.hasAccountSwitched() else { break }
            }
        }
    }

    /// Returns only successfully handled source IDs. A non-ask is success, while
    /// an AI or persistence failure stays unacknowledged for the queue to retry.
    func classifyPendingMessages(_ items: [(chatUsername: String, msg: MessageInfo)]) async -> Set<String> {
        var completed: Set<String> = []
        let myUsername = reader.myUsername()
        let myDisplayName = reader.displayName(for: myUsername)
        guard !myUsername.isEmpty, !reader.hasAccountSwitched() else { return completed }
        // One snapshot for the whole drain: the admission rules are consulted
        // per item, and re-reading them per message would put several queries on
        // a path that runs for every queued message.
        let admissionRules = AdmissionRules.load(store: store)
        for item in items {
            guard !Task.isCancelled, !reader.hasAccountSwitched() else { break }
            let msg = item.msg
            // Recheck scope at consumption time: the user may have removed a chat
            // or ignored a sender while this item was backing off.
            guard item.chatUsername == msg.chatUsername,
                  store.isWhitelisted(item.chatUsername),
                  !admissionRules.isMuted(
                      chatUsername: msg.chatUsername,
                      senderUsername: msg.senderUsername,
                      senderName: msg.senderName
                  ),
                  !MessageHelpers.isFromSelf(msg, chatUsername: msg.chatUsername, myUsername: myUsername,
                                             myDisplayName: myDisplayName, mySelfNames: reader.mySelfNames) else {
                completed.insert(msg.id)
                continue
            }
            let input = ClassifierInput(msgUID: msg.id, text: msg.text, senderName: msg.senderName,
                                        chatName: msg.chatName, isGroup: msg.chatUsername.contains("@chatroom"))
            // SQL bounds precede LIMIT: an old queued message gets its own prior
            // context, never whatever happens to be latest today. Exclude the whole
            // target second to avoid incorporating later same-second messages.
            let contextMessages = (try? reader.getMessages(
                chatUsername: msg.chatUsername, limit: 12, afterCursor: nil,
                startTime: msg.createTime - 86400, endTime: msg.createTime
            )) ?? []
            let context = contextMessages.reversed().map { "\($0.senderName): \($0.text)" }.joined(separator: "\n")
            var knownOtherNames = Set(store.loadContacts()
                .filter { $0.username != myUsername }
                .flatMap { [$0.username, $0.displayName] }
                .filter { !$0.isEmpty })
            for preceding in contextMessages where !MessageHelpers.isFromSelf(
                preceding, chatUsername: msg.chatUsername, myUsername: myUsername,
                myDisplayName: myDisplayName, mySelfNames: reader.mySelfNames
            ) {
                knownOtherNames.formUnion([preceding.senderUsername, preceding.senderName].filter { !$0.isEmpty })
            }
            let recipientContext = AIClassifier.RecipientContext(
                myUsername: myUsername, myDisplayName: myDisplayName,
                mySelfNames: reader.mySelfNames, knownOtherNames: knownOtherNames,
                precedingMessages: context
            )
            guard let result = await aiClassifier.classify(message: input, recipientContext: recipientContext) else { continue }
            guard !reader.hasAccountSwitched() else { break }
            guard result.isAsk, result.confidence >= 0.5 else {
                completed.insert(msg.id)
                continue
            }
            // Scope can change while the provider is answering as well.
            guard store.isWhitelisted(msg.chatUsername),
                  !admissionRules.isMuted(
                      chatUsername: msg.chatUsername,
                      senderUsername: msg.senderUsername,
                      senderName: msg.senderName
                  ) else {
                completed.insert(msg.id)
                continue
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
}
