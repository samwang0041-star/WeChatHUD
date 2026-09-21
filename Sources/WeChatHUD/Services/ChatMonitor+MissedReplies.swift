import Foundation

extension ChatMonitor {
    /// Reload the missed-reply list for `start...end`. A newer request
    /// cancels the previous walk so flipping 今天 / 近 7 天 does not apply
    /// a stale page.
    func refreshMissedReplies(start: Date, end: Date) {
        missedReplyTask?.cancel()
        let generation = UUID()
        missedReplyGeneration = generation
        missedReplyLoading = true
        missedReplyError = nil
        missedReplyCoverage = nil

        if PreviewRuntime.isEnabled {
            missedReplies = PreviewRuntime.missedReplyFixtures().filter {
                $0.timestamp >= start && $0.timestamp <= end
            }
            missedReplyCoverage = PreviewRuntime.missedRepliesCoverageOverride ?? .complete
            missedReplyLoading = false
            return
        }

        let rules = AdmissionRules.load(store: store)
        // 读不到关注名单，就没有「该回谁」的范围。原来的空数组会让这一页
        // 打印「都回过了」—— 那是一句关于完整性的断言，而这次根本没看到名单。
        let whitelist: [WhitelistEntry]
        switch store.whitelistAllRead() {
        case .value(let entries):
            whitelist = entries
        case .unreadable:
            missedReplyLoading = false
            missedReplyError = CompanionInteractionCopy.followListUnreadableMissedReplies
            return
        }
        let readerRef = reader
        let myUname = myUsername
        let myDisplay = myDisplayName
        let selfNames = reader.mySelfNames

        missedReplyTask = Task { [weak self] in
            let items: [MissedReplyFinder.Item]
            let coverage: MissedReplyFinder.Coverage
            do {
                let scan = try await OffMainWork.runThrowing(qos: .userInitiated) {
                    ScanEngine.buildMissedReplyItems(
                        reader: readerRef,
                        admissionRules: rules,
                        whitelist: whitelist,
                        myUsername: myUname,
                        myDisplayName: myDisplay,
                        mySelfNames: selfNames,
                        rangeStart: start,
                        rangeEnd: end,
                        now: Date()
                    )
                }
                items = scan.items
                coverage = scan.coverage
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.missedReplyGeneration == generation else { return }
                self.missedReplyLoading = false
                self.missedReplyError = CompanionInteractionCopy.missedRepliesFailed
                return
            }
            guard let self, self.missedReplyGeneration == generation else { return }
            self.missedReplies = items
            self.missedReplyCoverage = coverage
            self.missedReplyLoading = false
        }
    }
}
