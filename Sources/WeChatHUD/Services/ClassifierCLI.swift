import Foundation

/// Tiny CLI surface for AI services — invoked from `main.swift` before
/// the GUI launches. Exposes every AI role as a one-shot terminal command
/// so prompt iteration and sanity testing don't require the full HUD.
///
/// Subcommands:
///   classify <text> [--sender N] [--chat N] [--group]
///   classify-fixture <path>
///   classify-real [--per-chat N] [--max-total N] [--include-groups] [--out P]
///   suggest-reply <text> [--sender N] [--chat N] [--group] [--type yes_no|...]
///   group-catchup <chat_username> [--limit N]
///   categorize <chat_username> [--limit N]
///   retrospect [--date YYYY-MM-DD]
///
/// Always exits the process — never returns to caller.
enum ClassifierCLI {
    static func run(args: [String], subcommand: String) -> Never {
        switch subcommand {
        case "classify":
            runClassify(args: args)
        case "classify-fixture":
            runFixture(args: args)
        case "classify-real":
            runReal(args: args)
        case "suggest-reply":
            runSuggestReply(args: args)
        case "group-catchup":
            runGroupCatchup(args: args)
        case "categorize":
            runCategorize(args: args)
        case "retrospect":
            runRetrospect(args: args)
        default:
            fputs("unknown subcommand: \(subcommand)\n", stderr)
            exit(2)
        }
    }

    // MARK: - classify <text>

    private static func runClassify(args: [String]) -> Never {
        guard let firstArg = args.first, !firstArg.hasPrefix("--") else {
            fputs("usage: WeChatHUD classify \"<message text>\" [--sender NAME] [--chat NAME] [--group]\n", stderr)
            exit(2)
        }

        let text = firstArg
        var sender = "测试发送者"
        var chat = "测试聊天"
        var isGroup = false

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--sender":
                if i + 1 < args.count { sender = args[i + 1]; i += 2 } else { i += 1 }
            case "--chat":
                if i + 1 < args.count { chat = args[i + 1]; i += 2 } else { i += 1 }
            case "--group":
                isGroup = true; i += 1
            default:
                i += 1
            }
        }

        let store = makeStore()
        let classifier = makeClassifier(store: store)
        let input = ClassifierInput(
            msgUID: "cli-\(Int(Date().timeIntervalSince1970))",
            text: text,
            senderName: sender,
            chatName: chat,
            isGroup: isGroup
        )

        let started = Date()
        let result = runAsync { await classifier.classify(message: input) }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)

        if let r = result {
            let json: [String: Any] = [
                "is_ask": r.isAsk,
                "type": r.type.rawValue,
                "summary": r.summary,
                "deadline_relative": r.deadlineRelative as Any,
                "confidence": r.confidence,
                "prompt_version": r.promptVersion
            ]
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            } else {
                print("\(r)")
            }
            fputs("[\(elapsed)ms]\n", stderr)
            exit(0)
        } else {
            fputs("classifier returned nil — see ai_audit table for details\n", stderr)
            exit(1)
        }
    }

    // MARK: - classify-fixture <path>

    private static func runFixture(args: [String]) -> Never {
        guard let path = args.first else {
            fputs("usage: WeChatHUD classify-fixture <path/to/labeled_messages.json>\n", stderr)
            exit(2)
        }

        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            fputs("could not read \(path): \(error)\n", stderr)
            exit(2)
        }

        struct LabeledExpected: Decodable {
            let isAsk: Bool
            let type: String?
            let summary: String?
            let deadlineRelative: String?

            enum CodingKeys: String, CodingKey {
                case isAsk = "is_ask"
                case type
                case summary
                case deadlineRelative = "deadline_relative"
            }
        }

        struct LabeledCase: Decodable {
            let msgID: String
            let text: String
            let senderName: String?
            let chatKind: String?
            let expected: LabeledExpected

            enum CodingKeys: String, CodingKey {
                case msgID = "msg_id"
                case text
                case senderName = "sender_name"
                case chatKind = "chat_kind"
                case expected
            }
        }

        let cases: [LabeledCase]
        do {
            cases = try JSONDecoder().decode([LabeledCase].self, from: data)
        } catch {
            fputs("fixture decode failed: \(error)\n", stderr)
            exit(2)
        }

        let store = makeStore()
        let classifier = makeClassifier(store: store)

        var tp = 0, fp = 0, tn = 0, fn = 0
        var failures: [String] = []

        for c in cases {
            let input = ClassifierInput(
                msgUID: c.msgID,
                text: c.text,
                senderName: c.senderName ?? "<unknown>",
                chatName: "<fixture>",
                isGroup: c.chatKind == "group"
            )
            guard let r = runAsync({ await classifier.classify(message: input) }) else {
                failures.append("\(c.msgID): classifier returned nil")
                continue
            }
            switch (c.expected.isAsk, r.isAsk) {
            case (true, true):   tp += 1
            case (true, false):  fn += 1; failures.append("\(c.msgID): expected ask, got none — text='\(c.text)'")
            case (false, true):  fp += 1; failures.append("\(c.msgID): false positive (\(r.type.rawValue), \(r.summary)) — text='\(c.text)'")
            case (false, false): tn += 1
            }
        }

        let total = tp + fp + tn + fn
        let precision = (tp + fp) > 0 ? Double(tp) / Double(tp + fp) : 0
        let recall    = (tp + fn) > 0 ? Double(tp) / Double(tp + fn) : 0
        let f1        = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0

        print("===== Classifier fixture results =====")
        print("Cases: \(total)  TP=\(tp)  FP=\(fp)  TN=\(tn)  FN=\(fn)")
        print(String(format: "Precision: %.3f", precision))
        print(String(format: "Recall:    %.3f", recall))
        print(String(format: "F1:        %.3f", f1))
        if !failures.isEmpty {
            print("\nFailures:")
            for f in failures.prefix(20) { print("  - \(f)") }
            if failures.count > 20 { print("  ... \(failures.count - 20) more") }
        }

        exit(f1 >= 0.85 ? 0 : 1)
    }

    // MARK: - classify-real <flags>
    //
    // Pulls real messages from the user's WeChat DB (whitelist contacts
    // by default), runs each through the classifier, and writes a fixture-
    // shaped JSON the user can hand-label and add to a private fixture.
    //
    // Privacy: defaults to writing to /tmp so nothing accidentally lands
    // in git. The committed `Tests/Fixtures/labeled_messages.json` should
    // stay small and synthetic; the private file at
    // `Tests/Fixtures/labeled_messages_private.json` (gitignored) is where
    // real-message growth happens.

    private static func runReal(args: [String]) -> Never {
        var perChat = 10
        var outPath = "/tmp/wchud_classify_real_\(Int(Date().timeIntervalSince1970)).json"
        var includeGroups = false
        var maxTotal = 100   // hard cap so we don't accidentally chew through hours of GPU time

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--per-chat":
                if i + 1 < args.count, let n = Int(args[i + 1]) { perChat = n; i += 2 } else { i += 1 }
            case "--out":
                if i + 1 < args.count { outPath = args[i + 1]; i += 2 } else { i += 1 }
            case "--include-groups":
                includeGroups = true; i += 1
            case "--max-total":
                if i + 1 < args.count, let n = Int(args[i + 1]) { maxTotal = n; i += 2 } else { i += 1 }
            default:
                i += 1
            }
        }

        let store = makeStore()
        let classifier = makeClassifier(store: store)

        // Use whatever the user has configured (or default) for the
        // sync / cache strategy.
        let syncCfg = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        let reader = WeChatReader(cacheStrategy: syncCfg.cacheStrategy)
        do {
            try reader.loadKeys()
            try reader.loadContacts()
        } catch {
            fputs("WeChatReader bootstrap failed: \(error)\n", stderr)
            exit(2)
        }

        let myUsername = reader.myUsername()
        let whitelist = store.getWhitelist()
        if whitelist.isEmpty {
            fputs("白名单为空，没有可分类的真实消息。\n", stderr)
            exit(2)
        }

        // Collect candidate messages first, classify second. This lets
        // us cap the total volume up front and gives a deterministic
        // ordering when we write the fixture.
        struct Candidate {
            let msgUID: String
            let chatUsername: String
            let chatName: String
            let senderName: String
            let isGroup: Bool
            let text: String
            let createTime: Int
        }

        var candidates: [Candidate] = []
        var fetchErrors = 0

        for entry in whitelist {
            if entry.isGroup && !includeGroups { continue }
            if candidates.count >= maxTotal { break }

            let msgs: [MessageInfo]
            do {
                msgs = try reader.getMessages(chatUsername: entry.id, limit: perChat)
            } catch {
                fetchErrors += 1
                continue
            }

            for m in msgs {
                if candidates.count >= maxTotal { break }
                // Skip outbound (we only classify inbound asks).
                if !myUsername.isEmpty, m.senderUsername == myUsername { continue }
                // Skip empty / system / non-text messages.
                let trimmed = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if trimmed.count < 2 { continue }
                // Skip pure media tags like "[图片]" "[视频]" — they're
                // never asks and just dilute the sample.
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed.count < 12 { continue }

                candidates.append(Candidate(
                    msgUID: m.id,
                    chatUsername: m.chatUsername,
                    chatName: m.chatName,
                    senderName: m.senderName,
                    isGroup: entry.isGroup,
                    text: trimmed,
                    createTime: m.createTime
                ))
            }
        }

        if candidates.isEmpty {
            fputs("没有可分类的候选消息（fetchErrors=\(fetchErrors)）。\n", stderr)
            exit(1)
        }

        print("===== classify-real =====")
        print("白名单: \(whitelist.count) 个；候选消息: \(candidates.count) 条")
        print("模型: \(makeClassifierConfig(store: store).model)")
        print("输出: \(outPath)")
        print("")
        print(rowLine(sender: "sender", type: "type", isAsk: "ask", conf: "conf", lat: "ms", text: "text"))
        print(String(repeating: "─", count: 100))

        // Build fixture-format output as we go so we can save partial
        // results even if something blows up midway.
        var fixtureRows: [[String: Any]] = []

        var tally: [String: Int] = [:]
        var askCount = 0
        var totalLatency = 0

        for c in candidates {
            let input = ClassifierInput(
                msgUID: c.msgUID,
                text: c.text,
                senderName: c.senderName,
                chatName: c.chatName,
                isGroup: c.isGroup
            )
            let started = Date()
            let result = runAsync { await classifier.classify(message: input) }
            let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            totalLatency += latencyMs

            let typeStr: String
            let isAskStr: String
            let confStr: String
            if let r = result {
                typeStr = r.type.rawValue
                isAskStr = r.isAsk ? "✓" : "·"
                confStr = String(format: "%.2f", r.confidence)
                if r.isAsk { askCount += 1 }
                tally[r.type.rawValue, default: 0] += 1
            } else {
                typeStr = "ERR"
                isAskStr = "?"
                confStr = "—"
                tally["error", default: 0] += 1
            }

            let truncatedText = truncate(c.text, max: 50)
            print(rowLine(
                sender: truncate(c.senderName, max: 20),
                type: typeStr,
                isAsk: isAskStr,
                conf: confStr,
                lat: "\(latencyMs)",
                text: truncatedText
            ))

            // Fixture row — `expected` is intentionally null so the user
            // hand-labels each entry before adding to the test set. We
            // include the model's prediction in `predicted` so the user
            // can see what to flip.
            var row: [String: Any] = [
                "msg_id": c.msgUID,
                "text": c.text,
                "sender_name": c.senderName,
                "chat_kind": c.isGroup ? "group" : "private",
                "expected": NSNull()
            ]
            if let r = result {
                row["predicted"] = [
                    "is_ask": r.isAsk,
                    "type": r.type.rawValue,
                    "summary": r.summary,
                    "deadline_relative": r.deadlineRelative as Any,
                    "confidence": r.confidence
                ] as [String: Any]
            }
            fixtureRows.append(row)
        }

        print(String(repeating: "─", count: 100))
        let avgLatency = candidates.isEmpty ? 0 : totalLatency / candidates.count
        print("总数: \(candidates.count)  is_ask: \(askCount)  平均延迟: \(avgLatency)ms")
        print("类型分布:")
        for (k, v) in tally.sorted(by: { $0.value > $1.value }) {
            print("  \(k): \(v)")
        }

        // Write fixture-format file.
        do {
            let json = try JSONSerialization.data(
                withJSONObject: fixtureRows,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try json.write(to: URL(fileURLWithPath: outPath))
            print("\n已写入: \(outPath)")
            print("下一步：人工核对 `expected` 字段，把好用的样本合并到 Tests/Fixtures/labeled_messages_private.json")
        } catch {
            fputs("写入 \(outPath) 失败: \(error)\n", stderr)
            exit(1)
        }

        exit(0)
    }

    private static func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max - 1)
        return String(s[..<idx]) + "…"
    }

    /// Manual fixed-width row formatter. Avoids `String(format:"%-Ns",...)`
    /// which crashes when fed a Swift `String` because `%s` expects a C
    /// pointer and Swift's String is not a CVarArg in that form.
    /// Pads or truncates each cell to a fixed display width using
    /// character count (not byte count) so CJK lines roughly align.
    private static func rowLine(sender: String, type: String, isAsk: String, conf: String, lat: String, text: String) -> String {
        return pad(sender, 22) + " " +
               pad(type, 10) + " " +
               pad(isAsk, 5) + " " +
               pad(conf, 6) + " " +
               pad(lat, 7) + " " +
               text
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return String(s.prefix(width)) }
        return s + String(repeating: " ", count: width - s.count)
    }

    // MARK: - suggest-reply <text>

    private static func runSuggestReply(args: [String]) -> Never {
        guard let firstArg = args.first, !firstArg.hasPrefix("--") else {
            fputs("usage: WeChatHUD suggest-reply \"<message text>\" [--sender N] [--chat N] [--group] [--type yes_no|info|...]\n", stderr)
            exit(2)
        }

        let text = firstArg
        var sender = "测试发送者"
        var chat = "测试聊天"
        var isGroup = false
        var typeStr = "info"
        var relationship = "unknown"

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--sender":
                if i + 1 < args.count { sender = args[i + 1]; i += 2 } else { i += 1 }
            case "--chat":
                if i + 1 < args.count { chat = args[i + 1]; i += 2 } else { i += 1 }
            case "--group":
                isGroup = true; i += 1
            case "--type":
                if i + 1 < args.count { typeStr = args[i + 1]; i += 2 } else { i += 1 }
            case "--relationship":
                if i + 1 < args.count { relationship = args[i + 1]; i += 2 } else { i += 1 }
            default:
                i += 1
            }
        }

        let store = makeStore()
        let suggester = AIReplySuggester(store: store, aiService: AIService(config: store.loadAIConfig()))
        let askType = AskType(rawValue: typeStr) ?? .info
        let senderName = sender
        let chatName = chat
        let groupFlag = isGroup
        let relationshipValue = relationship

        let started = Date()
        let result = runAsync {
            await suggester.suggest(.init(
                messageBody: text,
                senderName: senderName,
                chatName: chatName,
                isGroup: groupFlag,
                askType: askType,
                relationship: relationshipValue
            ))
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)

        guard let suggestions = result else {
            fputs("AIReplySuggester returned nil — see ai_audit\n", stderr)
            exit(1)
        }

        print("===== reply suggestions =====")
        print("消息: \(text)")
        print("发送者: \(sender)  分类: \(typeStr)  关系: \(relationship)")
        print("")
        for (i, s) in suggestions.enumerated() {
            print("\(i + 1). [\(s.tone)] \(s.text)")
            print("   理由: \(s.rationale)")
        }
        fputs("[\(elapsed)ms]\n", stderr)
        exit(0)
    }

    // MARK: - group-catchup <chat_username>

    private static func runGroupCatchup(args: [String]) -> Never {
        guard let chatUsername = args.first, !chatUsername.hasPrefix("--") else {
            fputs("usage: WeChatHUD group-catchup <chat_username> [--limit N]\n", stderr)
            exit(2)
        }
        var limit = 30
        var i = 1
        while i < args.count {
            if args[i] == "--limit", i + 1 < args.count, let n = Int(args[i + 1]) {
                limit = n; i += 2
            } else {
                i += 1
            }
        }

        let store = makeStore()
        let syncCfg = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        let reader = WeChatReader(cacheStrategy: syncCfg.cacheStrategy)
        do {
            try reader.loadKeys()
            try reader.loadContacts()
        } catch {
            fputs("WeChatReader bootstrap failed: \(error)\n", stderr)
            exit(2)
        }

        let msgs: [MessageInfo]
        do {
            msgs = try reader.getMessages(chatUsername: chatUsername, limit: limit)
        } catch {
            fputs("could not load messages for \(chatUsername): \(error)\n", stderr)
            exit(2)
        }
        if msgs.isEmpty {
            fputs("no messages found for \(chatUsername)\n", stderr)
            exit(1)
        }

        // Sort chronological (oldest first), drop empty/system messages.
        let usable = msgs.sorted { $0.createTime < $1.createTime }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { !($0.text == "null" || $0.text == "(null)") }
            .map { (sender: $0.senderName, body: $0.text) }

        let chatName = msgs.first?.chatName ?? chatUsername
        let selfName = reader.displayName(for: reader.myUsername())

        let catchup = AIGroupCatchup(store: store, aiService: AIService(config: store.loadAIConfig()))
        let started = Date()
        let result = runAsync {
            await catchup.summarize(.init(chatName: chatName, selfName: selfName, messages: usable))
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)

        guard let summary = result else {
            fputs("AIGroupCatchup returned nil — see ai_audit\n", stderr)
            exit(1)
        }

        print("===== group catchup =====")
        print("群: \(chatName)  消息数: \(usable.count)  延迟: \(elapsed)ms")
        print("")
        print("📋 \(summary.headline)")
        if !summary.highlights.isEmpty {
            print("")
            for h in summary.highlights {
                print("  • \(h)")
            }
        }
        print("")
        if summary.needsUserAction {
            print("⚠️  你需要做: \(summary.actionSummary)")
        } else if summary.skipSafe {
            print("✅ 可以跳过这段（噪音 \(Int(summary.noiseRatio * 100))%）")
        } else {
            print("ℹ️  没有 @ 你的事，但有信息可以扫一下")
        }
        exit(0)
    }

    // MARK: - categorize <chat_username>

    private static func runCategorize(args: [String]) -> Never {
        guard let chatUsername = args.first, !chatUsername.hasPrefix("--") else {
            fputs("usage: WeChatHUD categorize <chat_username> [--limit N]\n", stderr)
            exit(2)
        }
        var limit = 20
        var i = 1
        while i < args.count {
            if args[i] == "--limit", i + 1 < args.count, let n = Int(args[i + 1]) {
                limit = n; i += 2
            } else {
                i += 1
            }
        }

        let store = makeStore()
        let syncCfg = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        let reader = WeChatReader(cacheStrategy: syncCfg.cacheStrategy)
        do {
            try reader.loadKeys()
            try reader.loadContacts()
        } catch {
            fputs("WeChatReader bootstrap failed: \(error)\n", stderr)
            exit(2)
        }

        let msgs: [MessageInfo]
        do {
            msgs = try reader.getMessages(chatUsername: chatUsername, limit: limit)
        } catch {
            fputs("could not load messages for \(chatUsername): \(error)\n", stderr)
            exit(2)
        }
        if msgs.isEmpty {
            fputs("no messages found for \(chatUsername)\n", stderr)
            exit(1)
        }

        let usable = msgs.sorted { $0.createTime < $1.createTime }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { !($0.text == "null" || $0.text == "(null)") }
            .map { (sender: $0.senderName, body: $0.text) }

        let isGroup = chatUsername.contains("@chatroom")
        let contactName = msgs.first?.chatName ?? chatUsername

        let categorizer = AIWhitelistCategorizer(store: store, aiService: AIService(config: store.loadAIConfig()))
        let started = Date()
        let result = runAsync {
            await categorizer.categorize(.init(contactName: contactName, isGroup: isGroup, messages: usable))
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)

        guard let suggestion = result else {
            fputs("AIWhitelistCategorizer returned nil — see ai_audit\n", stderr)
            exit(1)
        }

        print("===== whitelist suggestion =====")
        print("联系人: \(contactName)  群聊: \(isGroup)  消息数: \(usable.count)  延迟: \(elapsed)ms")
        print("")
        print("分类: \(suggestion.category)  (置信度 \(String(format: "%.2f", suggestion.confidence)))")
        print("理由: \(suggestion.reason)")
        print("信号词: \(suggestion.signalKeywords.joined(separator: ", "))")
        print("建议加入白名单: \(suggestion.shouldWhitelist ? "✓" : "✗")")
        exit(0)
    }

    // MARK: - retrospect [--date YYYY-MM-DD]

    private static func runRetrospect(args: [String]) -> Never {
        var date = ISO8601DateFormatter().string(from: Date()).prefix(10).description

        var i = 0
        while i < args.count {
            if args[i] == "--date", i + 1 < args.count {
                date = args[i + 1]; i += 2
            } else {
                i += 1
            }
        }

        let store = makeStore()
        // Pull today's "done" + all "pending" asks.
        let allDone = store.loadPendingAsks(status: .done)
        let allPending = store.loadPendingAsks(status: .pending)

        // Filter "done" to those updated today (rough — uses local
        // calendar day boundaries).
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let handledToday = allDone.filter { $0.updatedAt >= todayStart }

        let retrospector = AIDailyRetrospector(store: store, config: store.loadAIConfig())
        let reportDate = date

        // For overnight build we don't have message_count or focus
        // duration tracking yet — pass placeholders.
        let started = Date()
        let result = runAsync {
            await retrospector.retrospect(.init(
                date: reportDate,
                handled: handledToday,
                pending: allPending,
                messageCount: 0,
                focusDurationMinutes: 0
            ))
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)

        guard let r = result else {
            fputs("AIDailyRetrospector returned nil — see ai_audit\n", stderr)
            exit(1)
        }

        print("===== daily retrospective \(date) =====")
        print("延迟: \(elapsed)ms")
        print("")
        print("📊 \(r.todaySummary)")
        print("")
        print("🌅 明早第一件事:")
        print("   \(r.tomorrowFirstThing.action)")
        print("   理由: \(r.tomorrowFirstThing.reason)")
        if r.tomorrowFirstThing.relatedAskId > 0 {
            print("   关联 ask: #\(r.tomorrowFirstThing.relatedAskId)")
        }
        print("")
        print("📈 处理 \(r.stats.asksHandled) / 待处理 \(r.stats.asksPending) / 超时 \(r.stats.asksOverdue)")
        print("")
        print("📝 微信日报草稿（可一键复制）：")
        print("─────")
        print(r.wechatDailyReport)
        print("─────")
        exit(0)
    }

    // MARK: - Wiring

    private static func makeStore() -> HUDStore {
        let store = HUDStore()
        do {
            try store.open()
        } catch {
            fputs("HUDStore.open failed: \(error)\n", stderr)
            exit(2)
        }
        return store
    }

    private static func makeClassifier(store: HUDStore) -> AIClassifier {
        return AIClassifier(store: store, aiService: AIService(config: makeClassifierConfig(store: store)))
    }

    /// Always reads via `HUDStore.loadAIConfig()` so the CLI
    /// never carries an inline endpoint URL or model name.
    private static func makeClassifierConfig(store: HUDStore) -> AIConfig {
        store.loadAIConfig()
    }

    /// Park the current (non-async) thread on a semaphore until the
    /// async closure resolves. We need this because `main.swift` is not
    /// in an async context and we want the CLI subcommands to feel like
    /// a one-shot blocking tool, not a background task that gets
    /// interrupted by the AppKit run loop.
    ///
    /// Uses a class box (declared at file scope below) to safely shuttle
    /// the result across the actor hop — the simpler `var result: T!`
    /// approach trips Swift 5.10's strict concurrency checking when `T`
    /// isn't `Sendable`.
    private static func runAsync<T>(_ work: @Sendable @escaping () async -> T) -> T {
        let box = ResultBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task {
            box.value = await work()
            sem.signal()
        }
        sem.wait()
        return box.value!
    }
}

/// Single-cell mutable container that can cross actor boundaries because
/// it's `@unchecked Sendable`. Used by `ClassifierCLI.runAsync` to ferry
/// the result of an async closure back to the synchronous caller.
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
