import AppKit
import ApplicationServices
import CoreGraphics

extension Notification.Name {
    /// Posted immediately before WeChatLauncher begins activating WeChat.
    /// Observed by AppDelegate to collapse the HUD panel so it doesn't
    /// overlap WeChat while the user interacts with it.
    static let hudWillOpenWeChat = Notification.Name("WeChatHUD.WillOpenWeChat")

    /// Posted after WeChatLauncher has finished the foreground UI
    /// automation (or failed before it could start). AppDelegate uses
    /// it to restore the HUD panel after temporarily hiding it.
    static let hudDidFinishWeChatAutomation = Notification.Name("WeChatHUD.DidFinishWeChatAutomation")

    /// Posted when WeChatLauncher fails in a way the user should see
    /// (Accessibility not granted, WeChat not running, search field
    /// missing, activation timeout). `userInfo["message"]` carries the
    /// human-readable message for the toast. Posted on main.
    static let hudLauncherFailed = Notification.Name("WeChatHUD.LauncherFailed")
}

/// Bridge between the HUD and WeChat.app for click-to-open navigation.
///
/// WeChat macOS has no URL scheme or scripting API for jumping directly
/// to a specific chat. We fake it by:
///
/// 1. Activating WeChat so its window is frontmost
/// 2. Stashing the current pasteboard contents
/// 3. Copying the target chat name onto the pasteboard
/// 4. Posting low-level CGEvents for `Cmd+F → Cmd+V → Return` — the
///    built-in search-to-chat workflow in WeChat jumps to the matching
///    conversation
/// 5. Restoring the user's original pasteboard after a short delay
///
/// We deliberately use CGEvent keystrokes instead of NSAppleScript +
/// System Events. AppleScript needs **Automation** TCC permission,
/// which requires `NSAppleEventsUsageDescription` in Info.plist AND a
/// fresh TCC state for the bundle ID — and modern macOS tends to just
/// silently deny with `errAEEventNotPermitted (-1743)` instead of
/// prompting once the bundle ID has any prior rejection on record.
/// CGEvent goes through the HID event tap and needs **Accessibility**
/// permission instead, which has a cleaner prompt flow.
enum WeChatLauncher {
    enum SendFailureReason: String, Equatable {
        case weChatNotRunning
        case previewMode
        case accessibilityDenied
        case lostForeground
        case chatMismatch
        case inputNotFound
        case accountUnverified
        case accountMismatch
        case operationInProgress

        var userMessage: String {
            switch self {
            case .previewMode: return "演示模式不会操作微信"
            case .accountUnverified: return "无法核验微信当前账号，已停止自动操作。回复内容仍在助手中，请在微信核对账号后手动回复。"
            case .accountMismatch: return "微信当前账号与助手数据账号不一致，已停止自动操作。请保留回复内容并核对账号。"
            case .operationInProgress: return "另一条回复正在处理，当前内容仍保留。请稍后重试。"
            case .weChatNotRunning:
                return "微信未运行"
            case .accessibilityDenied:
                return "macOS 尚未允许当前应用操作微信。若系统开关已开启，请重新打开 WeChatHUD 后再试。"
            case .lostForeground:
                return "微信窗口失去焦点，已取消发送"
            case .chatMismatch:
                return "当前聊天与目标不一致，已取消发送"
            case .inputNotFound:
                return "未找到微信输入框"
            }
        }
    }

    enum SendResult: Equatable {
        /// The send keystroke was posted; callers must verify a database receipt.
        case sent
        case failed(SendFailureReason)

        var succeeded: Bool {
            if case .sent = self { return true }
            return false
        }

        var failureMessage: String? {
            guard case .failed(let reason) = self else { return nil }
            return reason.userMessage
        }
    }

    private static let bundleIDs: Set<String> = [
        "com.tencent.xinWeChat",
        "com.tencent.WeChat"
    ]

    /// File-based debug logger. Stdout isn't captured when the app is
    /// launched via `open` (Launch Services), so we append every step
    /// of the click flow to a known path and read it from the terminal
    /// for troubleshooting.
    private static let logPath = "/tmp/wchud_launcher.log"

    private static func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    /// Surface a user-visible failure message. Previously every
    /// failure path just logged to `/tmp/wchud_launcher.log` — the
    /// user had no way to know why "在微信中打开" did nothing.
    private static func notifyUser(_ message: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .hudLauncherFailed,
                object: nil,
                userInfo: ["message": message]
            )
        }
    }

    private static func postWillOpenWeChat() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .hudWillOpenWeChat, object: nil)
        }
    }

    private static func postDidFinishWeChatAutomation() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .hudDidFinishWeChatAutomation, object: nil)
        }
    }

    // Virtual key codes (ANSI layout). These are hardware codes that
    // don't change with keyboard layout — good for our use case since
    // we're typing modifier+letter, not text.
    private static let kVK_ANSI_A: CGKeyCode = 0x00
    private static let kVK_ANSI_F: CGKeyCode = 0x03
    private static let kVK_ANSI_V: CGKeyCode = 0x09
    private static let kVK_Return: CGKeyCode = 0x24
    private static let kVK_Delete: CGKeyCode = 0x33
    private static let kVK_Escape: CGKeyCode = 0x35

    /// Bring WeChat forward, populate its search field with `chatName`,
    /// and submit — opening that conversation. Silently no-ops if WeChat
    /// isn't running (we don't try to launch it; the user typically
    /// keeps it running anyway).
    static func openChat(named chatName: String, searchNames: [String] = []) {
        Task { @MainActor in
            guard !PreviewRuntime.isEnabled else { return }
            guard !textActionInFlight else { notifyUser(SendFailureReason.operationInProgress.userMessage); return }
            textActionInFlight = true
            defer { textActionInFlight = false }
            guard let app = runningWeChat() else { notifyUser(SendFailureReason.weChatNotRunning.userMessage); return }
            guard let root = (NSApp.delegate as? AppDelegate)?.reader?.dbDir, !root.isEmpty,
                  let launchDate = app.launchDate, let bundleID = app.bundleIdentifier else {
                notifyUser(SendFailureReason.accountUnverified.userMessage)
                return
            }
            let binding = AccountBinding(
                processID: app.processIdentifier,
                launchDate: launchDate,
                bundleID: bundleID,
                databaseRoot: WeChatAccountEvidence.canonicalRoot(root)
            )
            if let failure = await accountFailure(binding) { notifyUser(failure.userMessage); return }
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(opts) else { notifyUser(SendFailureReason.accessibilityDenied.userMessage); return }
            let saved = ClipboardGuard.save()
            defer {
                ClipboardGuard.restore(saved)
                finishClipboardRestore()
            }
            let names = WeChatOpenSearch.names(stored: searchNames.isEmpty ? [chatName] : searchNames, username: chatName)
            if let failure = await navigateToChat(app: app, searchNames: names) { notifyUser(failure.userMessage) }
        }
    }

    /// Open a chat and paste `text` into the message input as an
    /// unsent draft. This is the right primitive for reply
    /// suggestions: copying first and then calling `openChat` is racy
    /// because `openChat` itself uses the pasteboard for WeChat search
    /// and only restores the previous clipboard.
    static func openChatAndPaste(named chatName: String, text: String, searchNames: [String] = []) {
        Task { @MainActor in
            let result = await performTextAction(chatName: chatName, text: text, typingDelay: 0, sendKey: nil, searchNames: searchNames)
            if case .failed(let reason) = result { notifyUser(reason.userMessage) }
        }
    }

    private static func findSearchItem(in axApp: AXUIElement, chatName: String) -> AXUIElement? {
        let targetID = "search_item_\(chatName)"
        return dfsAX(axApp, maxDepth: 40) { el in
            guard let identifier = axString(el, kAXIdentifierAttribute) else { return false }
            return identifier == targetID
        }
    }

    /// After opening a chat (via sidebar or search), land the focus in
    /// the message input so the user can type immediately. WeChat's
    /// normal behavior when you click a chat with the mouse is to do
    /// this automatically, but our synthetic click doesn't trigger it.
    ///
    /// Strategy: poll for an `AXTextArea` that is NOT the search field
    /// (title "Search"/"搜索"). When found, AX-focus it and also post
    /// a synthetic click at its center as a belt-and-braces measure.
    private static func findMessageInput(in axApp: AXUIElement) -> AXUIElement? {
        return dfsAX(axApp, maxDepth: 40) { el in
            guard let role = axString(el, kAXRoleAttribute),
                  role == kAXTextAreaRole else { return false }
            let title = axString(el, kAXTitleAttribute) ?? ""
            if title == "Search" || title == "搜索" { return false }
            // Skip zero-sized elements.
            guard let sizeRaw = axGet(el, kAXSizeAttribute) else { return false }
            var size = CGSize.zero
            guard AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size),
                  size.width > 10, size.height > 10 else { return false }
            return true
        }
    }

    // MARK: - AX tree helpers

    /// Fetch an AX attribute as the raw CFTypeRef. nil on error.
    private static func axGet(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        return axGet(element, attribute) as? String
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        guard let raw = axGet(element, kAXChildrenAttribute) else { return [] }
        return (raw as? [AXUIElement]) ?? []
    }

    /// DFS walk the AX tree looking for the first element matching
    /// `predicate`. We keep a depth cap to protect against pathological
    /// deep trees (WeChat's is typically 10–15 levels).
    private static func dfsAX(
        _ root: AXUIElement,
        depth: Int = 0,
        maxDepth: Int = 30,
        predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if predicate(root) { return root }
        if depth >= maxDepth { return nil }
        for child in axChildren(root) {
            if let match = dfsAX(child, depth: depth + 1, maxDepth: maxDepth, predicate: predicate) {
                return match
            }
        }
        return nil
    }

    /// Find a sidebar session element whose identifier is exactly
    /// `session_item_<chatName>`. Used to bypass the keyboard search
    /// entirely when the chat is in the visible session list.
    private static func findSessionItem(in axApp: AXUIElement, chatName: String) -> AXUIElement? {
        let targetID = "session_item_\(chatName)"
        let result = dfsAX(axApp) { el in
            guard let identifier = axString(el, kAXIdentifierAttribute) else { return false }
            return identifier == targetID
                || identifier.hasPrefix("session_item_") && identifier.contains(chatName)
        }
        if result == nil {
            // One-shot debug dump when we miss. Writes a structural
            // summary of every AX node that has a non-empty identifier
            // OR role == AXStaticText so we can see what WeChat 4.x
            // actually exposes.
            dumpAXTreeOnce(axApp, chatName: chatName)
        }
        return result
    }

    /// Read the name of the currently-open chat, if any. WeChat marks
    /// the title element with identifier `big_title_line_h_view`.
    /// Returns nil if no chat is visible (e.g. the main session list
    /// with nothing selected).
    private static func currentChatTitle(in axApp: AXUIElement) -> String? {
        guard let el = dfsAX(axApp, maxDepth: 40, predicate: { node in
            guard let role = axString(node, kAXRoleAttribute),
                  role == kAXStaticTextRole else { return false }
            guard let identifier = axString(node, kAXIdentifierAttribute) else { return false }
            return identifier == "big_title_line_h_view"
        }) else { return nil }
        if let value = axGet(el, kAXValueAttribute) as? String, !value.isEmpty {
            return value
        }
        if let title = axString(el, kAXTitleAttribute), !title.isEmpty {
            return title
        }
        return nil
    }

    /// Normalize a chat title for equality comparison. WeChat appends
    /// `(<N>)` for group member counts, e.g. "开发群(42)" — strip that
    /// so comparisons still match when member count changes.
    private static func normalizeChatTitle(_ name: String) -> String {
        var out = name.trimmingCharacters(in: .whitespaces)
        // Match trailing (<digits>) — both ASCII and full-width parens.
        if let range = out.range(of: #"[（(]\d+[）)]$"#, options: .regularExpression) {
            out.removeSubrange(range)
            out = out.trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Find WeChat's global-search text field. Exposed via AX as a
    /// `AXTextArea` with title "Search" / "搜索".
    private static func findSearchField(in axApp: AXUIElement) -> AXUIElement? {
        return dfsAX(axApp, maxDepth: 40) { el in
            guard let role = axString(el, kAXRoleAttribute),
                  role == kAXTextAreaRole else { return false }
            let title = axString(el, kAXTitleAttribute) ?? ""
            return title == "Search" || title == "搜索"
        }
    }

    /// Find the `search_list` AXList that holds global-search results.
    private static func findSearchList(in axApp: AXUIElement) -> AXUIElement? {
        return dfsAX(axApp, maxDepth: 40) { el in
            guard let role = axString(el, kAXRoleAttribute),
                  role == kAXListRole else { return false }
            guard let identifier = axString(el, kAXIdentifierAttribute) else { return false }
            return identifier == "search_list"
        }
    }

    private struct SearchEntry {
        let element: AXUIElement
        let text: String
        let y: CGFloat
    }

    /// Walk search_list, collect every static-text cell with position.
    /// Sorted top-to-bottom by Y so section headers are detectable.
    private static func collectSearchEntries(in searchList: AXUIElement) -> [SearchEntry] {
        var out: [SearchEntry] = []
        func walk(_ el: AXUIElement) {
            if let role = axString(el, kAXRoleAttribute), role == kAXStaticTextRole {
                let text = (axString(el, kAXTitleAttribute)
                            ?? (axGet(el, kAXValueAttribute) as? String)
                            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    var y: CGFloat = 0
                    if let posRaw = axGet(el, kAXPositionAttribute) {
                        var point = CGPoint.zero
                        if AXValueGetValue(posRaw as! AXValue, .cgPoint, &point) {
                            y = point.y
                        }
                    }
                    out.append(SearchEntry(element: el, text: text, y: y))
                }
            }
            for child in axChildren(el) { walk(child) }
        }
        walk(searchList)
        out.sort { $0.y < $1.y }
        return out
    }

    /// Section header labels we recognize. Both English and Chinese.
    /// Entries classified as "Contacts" / "Group Chats" are valid
    /// match candidates; everything else (Chat History, Official
    /// Accounts, Internet results, More) is ignored so we don't jump
    /// into a public-account article.
    private static let sectionContacts: Set<String> = ["Contacts", "联系人"]
    private static let sectionGroupChats: Set<String> = ["Group Chats", "群聊"]
    private static let sectionNoise: Set<String> = [
        "Chat History", "聊天记录",
        "Official Accounts", "公众号",
        "Internet search results", "互联网搜索结果",
        "More", "更多",
    ]
    private static var allSectionLabels: Set<String> {
        return sectionContacts
            .union(sectionGroupChats)
            .union(sectionNoise)
    }

    /// Find an exact-text match in the search results, preferring
    /// Contacts section → Group Chats section. Uses the Y coordinate
    /// of each section header to classify entries that sit below it.
    private static func findExactMatch(
        in entries: [SearchEntry],
        chatName: String
    ) -> AXUIElement? {
        // Y position of each known header.
        var headerY: [String: CGFloat] = [:]
        for entry in entries where allSectionLabels.contains(entry.text) {
            // Normalize Chinese to canonical English for easier lookup.
            let canonical: String
            if sectionContacts.contains(entry.text) { canonical = "Contacts" }
            else if sectionGroupChats.contains(entry.text) { canonical = "Group Chats" }
            else { canonical = entry.text }
            headerY[canonical] = entry.y
        }

        func sectionOf(_ y: CGFloat) -> String? {
            var bestHeader: String?
            var bestY = -CGFloat.infinity
            for (h, hy) in headerY where hy <= y && hy > bestY {
                bestHeader = h
                bestY = hy
            }
            return bestHeader
        }

        var contactHit: AXUIElement?
        var groupHit: AXUIElement?
        for entry in entries {
            if entry.text != chatName { continue }
            if allSectionLabels.contains(entry.text) { continue }
            switch sectionOf(entry.y) {
            case "Contacts":
                if contactHit == nil { contactHit = entry.element }
            case "Group Chats":
                if groupHit == nil { groupHit = entry.element }
            default:
                break
            }
        }
        return contactHit ?? groupHit
    }

    private static var axDumped = false
    private static var searchListDumped = false
    private static func dumpAXTreeOnce(_ root: AXUIElement, chatName: String) {
        guard !axDumped else { return }
        axDumped = true
        log("=== AX tree dump (looking for \(chatName)) ===")
        dumpAX(root, depth: 0)
        log("=== end AX tree dump ===")
    }

    private static func dumpAX(_ element: AXUIElement, depth: Int, maxDepth: Int = 40) {
        if depth > maxDepth { return }
        let role = axString(element, kAXRoleAttribute) ?? "?"
        let identifier = axString(element, kAXIdentifierAttribute) ?? ""
        let title = axString(element, kAXTitleAttribute) ?? ""
        let valueStr = (axGet(element, kAXValueAttribute) as? String) ?? ""
        // Only log interesting nodes — identifier, title, or text value.
        if !identifier.isEmpty || !title.isEmpty || !valueStr.isEmpty {
            let indent = String(repeating: "  ", count: depth)
            let preview = String(valueStr.prefix(40))
            log("\(indent)[\(role)] id=\(identifier) title=\(title) val=\(preview)")
        }
        for child in axChildren(element) {
            dumpAX(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    /// Post a synthetic left-click at the visual center of an AX
    /// element. Returns false if we couldn't resolve the element's
    /// on-screen bounds.
    private static func clickAXElementCenter(_ element: AXUIElement) -> Bool {
        guard let posRaw = axGet(element, kAXPositionAttribute),
              let sizeRaw = axGet(element, kAXSizeAttribute) else {
            log("AX: element missing position/size")
            return false
        }
        // Both values come back wrapped in AXValue; unbox via the
        // type-specific accessor.
        let posValue = posRaw as! AXValue
        let sizeValue = sizeRaw as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            log("AX: failed to unbox position/size")
            return false
        }
        let cx = point.x + size.width / 2.0
        let cy = point.y + size.height / 2.0
        let center = CGPoint(x: cx, y: cy)
        log("AX: clicking at (\(Int(cx)), \(Int(cy)))")

        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return true
    }

    /// Poll `NSWorkspace.frontmostApplication` every 40ms up to `timeout`
    /// seconds, waiting for the target app to own the active slot.
    /// Returns via `completion(true)` on success, `completion(false)` on
    /// timeout. Logs the terminal state either way.
    private static func waitUntilFrontmost(
        app: NSRunningApplication,
        timeout: TimeInterval = 1.5,
        completion: @escaping (Bool) -> Void
    ) {
        let start = Date()
        let targetID = app.bundleIdentifier
        func poll() {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier == targetID {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                log("WeChat frontmost after \(ms)ms")
                completion(true)
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                log("waitUntilFrontmost timed out; frontmost=\(front?.bundleIdentifier ?? "nil")")
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { poll() }
        }
        poll()
    }

    private static func finishClipboardRestore() {
        log("clipboard restored")
        postDidFinishWeChatAutomation()
    }

    /// Bring WeChat to the foreground from a background / accessory
    /// process. Tries the NSWorkspace openApplication path first and
    /// falls back to `/usr/bin/open -a` via Process if the bundle URL
    /// isn't known. `completion(true)` fires once WeChat is frontmost.
    private static func activateWeChat(app: NSRunningApplication, completion: @escaping (Bool) -> Void) {
        if let url = app.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier ?? "") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.addsToRecentItems = false
            log("NSWorkspace.openApplication at \(url.path)")
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                DispatchQueue.main.async {
                    if let error = error {
                        log("openApplication error: \(error.localizedDescription)")
                        completion(false)
                    } else {
                        log("openApplication succeeded")
                        completion(true)
                    }
                }
            }
            return
        }
        // Last-ditch: shell out to `open -a WeChat`. Not as precise but
        // works when bundleURL is unknown.
        log("bundleURL missing; shelling out to /usr/bin/open")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "WeChat"]
        do {
            try task.run()
            // No async signal from Process for "activation done"; give
            // it a fixed moment and assume success.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                completion(true)
            }
        } catch {
            log("/usr/bin/open failed: \(error.localizedDescription)")
            completion(false)
        }
    }

    /// Post a single key down + key up event with Command held.
    private static func postCmdKey(_ keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Post a single key down + key up event with no modifiers.
    private static func postKey(_ keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Simulate Cmd+V paste into the frontmost application.
    static func pasteClipboard() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Copy arbitrary text to the user's clipboard. Used by the
    /// Cmd+Click shortcut on message rows.
    static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Send a text message to a chat by name. Opens the chat, pastes
    /// the message text, and submits it via Return key.
    /// Returns true if the sequence completed without obvious error.
    /// Send a message to a chat. If `typingDelay` > 0, text is pasted into the input
    /// box first and the send keystroke is delayed to simulate human typing time.
    static func sendMessage(
        chatName: String,
        text: String,
        typingDelay: TimeInterval = 0,
        sendKey: WeChatSendKey = .cmdEnter
    ) async -> Bool {
        await sendMessageDetailed(
            chatName: chatName,
            text: text,
            typingDelay: typingDelay,
            sendKey: sendKey
        ).succeeded
    }

    static func sendMessageDetailed(
        chatName: String,
        text: String,
        typingDelay: TimeInterval = 0,
        sendKey: WeChatSendKey = .cmdEnter,
        searchNames: [String] = []
    ) async -> SendResult {
        switch await performTextAction(chatName: chatName, text: text, typingDelay: typingDelay, sendKey: sendKey, searchNames: searchNames) {
        case .completed: return .sent
        case .failed(let reason): return .failed(reason)
        }
    }

    @MainActor private static var textActionInFlight = false

    private enum TextActionOutcome {
        case completed
        case failed(SendFailureReason)
    }

    private struct AccountBinding {
        let processID: Int32
        let launchDate: Date
        let bundleID: String
        let databaseRoot: String
    }

    /// The only path that places reply text into WeChat. A matching chat title
    /// cannot establish an account, so verify process database evidence before
    /// navigation, before paste, and once more immediately before the send key.
    @MainActor private static func performTextAction(
        chatName: String, text: String, typingDelay: TimeInterval, sendKey: WeChatSendKey?,
        searchNames: [String] = []
    ) async -> TextActionOutcome {
        let searchNames = WeChatOpenSearch.names(stored: searchNames.isEmpty ? [chatName] : searchNames, username: chatName)
        guard !PreviewRuntime.isEnabled else { return .failed(.previewMode) }
        guard !textActionInFlight else { return .failed(.operationInProgress) }
        textActionInFlight = true
        defer { textActionInFlight = false }
        guard let app = runningWeChat() else { return .failed(.weChatNotRunning) }
        guard let root = (NSApp.delegate as? AppDelegate)?.reader?.dbDir, !root.isEmpty,
              let launchDate = app.launchDate, let bundleID = app.bundleIdentifier else { return .failed(.accountUnverified) }
        let binding = AccountBinding(processID: app.processIdentifier, launchDate: launchDate,
                                     bundleID: bundleID, databaseRoot: WeChatAccountEvidence.canonicalRoot(root))
        if let failure = await accountFailure(binding) { return .failed(failure) }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { return .failed(.accessibilityDenied) }
        let pasteboard = NSPasteboard.general
        let saved = ClipboardGuard.save()
        defer {
            ClipboardGuard.restore(saved)
            finishClipboardRestore()
        }
        let axApp = AXUIElementCreateApplication(binding.processID)
        if let failure = await navigateToChat(app: app, searchNames: searchNames) { return .failed(failure) }
        guard isWeChatFrontmost(app) else { return .failed(.lostForeground) }
        guard isCurrentChat(axApp: axApp, searchNames: searchNames) else { return .failed(.chatMismatch) }
        guard let input = findMessageInput(in: axApp) else { return .failed(.inputNotFound) }
        _ = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = clickAXElementCenter(input)
        guard await pause(max(0.2, typingDelay)) else { return .failed(.accountUnverified) }
        if let failure = await accountFailure(binding) { return .failed(failure) }
        guard isWeChatFrontmost(app) else { return .failed(.lostForeground) }
        guard isCurrentChat(axApp: axApp, searchNames: searchNames) else { return .failed(.chatMismatch) }
        _ = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        postCmdKey(kVK_ANSI_A)
        guard await pause(0.05) else { return .failed(.accountUnverified) }
        // Check again after the asynchronous gap before any reply text is pasted.
        if let failure = await accountFailure(binding) { return .failed(failure) }
        guard isWeChatFrontmost(app) else { return .failed(.lostForeground) }
        guard isCurrentChat(axApp: axApp, searchNames: searchNames) else { return .failed(.chatMismatch) }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postCmdKey(kVK_ANSI_V)
        // Keep the reply on the pasteboard until the queued paste event is consumed.
        guard await pause(0.15) else {
            retractPastedDraft(axApp: axApp)
            return .failed(.accountUnverified)
        }
        guard let sendKey else { return .completed }
        if let failure = await accountFailure(binding) {
            retractPastedDraft(axApp: axApp)
            return .failed(failure)
        }
        guard isWeChatFrontmost(app) else {
            retractPastedDraft(axApp: axApp)
            return .failed(.lostForeground)
        }
        guard isCurrentChat(axApp: axApp, searchNames: searchNames) else {
            retractPastedDraft(axApp: axApp)
            return .failed(.chatMismatch)
        }
        switch sendKey {
        case .cmdEnter: postCmdKey(kVK_Return)
        case .enter: postKey(kVK_Return)
        }
        log("sendMessage: account-verified submit to \(chatName)")
        return .completed
    }

    /// Every navigation step is awaited while the shared automation lock is held.
    /// No delayed search or clipboard callback survives this method's return.
    @MainActor private static func navigateToChat(app: NSRunningApplication, searchNames: [String]) async -> SendFailureReason? {
        postWillOpenWeChat()
        let activated = await withCheckedContinuation { continuation in
            activateWeChat(app: app) { continuation.resume(returning: $0) }
        }
        guard activated else { return .lostForeground }
        for _ in 0..<40 {
            if isWeChatFrontmost(app) { break }
            guard await pause(0.04) else { return .lostForeground }
        }
        guard isWeChatFrontmost(app), await pause(0.08) else { return .lostForeground }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Do not use sidebar substring matching: similarly named chats are distinct.
        guard let search = findSearchField(in: axApp), clickAXElementCenter(search) else { return .inputNotFound }
        guard await pause(0.12), isWeChatFrontmost(app) else { return .lostForeground }
        let names = searchNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return .chatMismatch }
        for (index, chatName) in names.enumerated() {
            _ = AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            postCmdKey(kVK_ANSI_A)
            guard await pause(0.05), isWeChatFrontmost(app) else { return .lostForeground }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(chatName, forType: .string)
            postCmdKey(kVK_ANSI_V)
            guard await pause(index == 0 ? 0.4 : 0.25) else { return .lostForeground }
            var sawMatch = false
            for _ in 0..<12 {
                guard isWeChatFrontmost(app), !Task.isCancelled else { return .lostForeground }
                var matches: [AXUIElement] = []
                var remaining = 5000
                func collect(_ element: AXUIElement, depth: Int) {
                    guard depth <= 40, remaining > 0 else { return }
                    remaining -= 1
                    if axString(element, kAXIdentifierAttribute) == "search_item_\(chatName)" { matches.append(element) }
                    for child in axChildren(element) { collect(child, depth: depth + 1) }
                }
                collect(axApp, depth: 0)
                guard remaining > 0 else { return .chatMismatch }
                if matches.count > 1 { break }
                if let match = matches.first {
                    sawMatch = true
                    guard clickAXElementCenter(match) else { return .chatMismatch }
                    for _ in 0..<12 {
                        guard await pause(0.1), isWeChatFrontmost(app) else { return .lostForeground }
                        if isCurrentChat(axApp: axApp, searchNames: names), let input = findMessageInput(in: axApp) {
                            _ = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                            return clickAXElementCenter(input) ? nil : .inputNotFound
                        }
                    }
                    break
                }
                guard await pause(0.1) else { return .lostForeground }
            }
            if sawMatch { return .chatMismatch }
            log("sendMessage: WeChat search missed '\(chatName)', trying next name")
        }
        return .chatMismatch
    }

    @MainActor private static func retractPastedDraft(axApp: AXUIElement) {
        guard let input = findMessageInput(in: axApp) else { return }
        _ = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        postCmdKey(kVK_ANSI_A)
        postKey(kVK_Delete)
        log("retracted pasted draft after aborted send")
    }

    @MainActor private static func accountFailure(_ binding: AccountBinding) async -> SendFailureReason? {
        guard sameProcess(binding),
              let root = (NSApp.delegate as? AppDelegate)?.reader?.dbDir,
              WeChatAccountEvidence.canonicalRoot(root) == binding.databaseRoot else { return .accountUnverified }
        let verdict = await WeChatAccountEvidence.inspect(processID: binding.processID, expectedRoot: binding.databaseRoot)
        guard sameProcess(binding), !Task.isCancelled,
              let currentRoot = (NSApp.delegate as? AppDelegate)?.reader?.dbDir,
              WeChatAccountEvidence.canonicalRoot(currentRoot) == binding.databaseRoot else { return .accountUnverified }
        switch verdict {
        case .verified: return nil
        case .unverified: return .accountUnverified
        case .mismatch: return .accountMismatch
        }
    }

    private static func sameProcess(_ binding: AccountBinding) -> Bool {
        guard let current = NSRunningApplication(processIdentifier: binding.processID) else { return false }
        return current.bundleIdentifier == binding.bundleID && WeChatAccountEvidence.processMatches(
            expectedPID: binding.processID, expectedLaunch: binding.launchDate,
            actualPID: current.processIdentifier, actualLaunch: current.launchDate, terminated: current.isTerminated
        )
    }

    private static func pause(_ seconds: TimeInterval) async -> Bool {
        do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)); return true }
        catch { return false }
    }

    private static func isWeChatFrontmost(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier && !app.isTerminated
    }

    private static func isCurrentChat(axApp: AXUIElement, searchNames: [String]) -> Bool {
        guard let currentTitle = currentChatTitle(in: axApp) else {
            log("sendMessage: unable to read current chat title")
            return false
        }
        let matches = WeChatOpenSearch.titleMatches(currentTitle, acceptable: searchNames)
        if !matches {
            log("sendMessage: expected chat \(searchNames), current title '\(currentTitle)'")
        }
        return matches
    }

    private static func runningWeChat() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard let bid = app.bundleIdentifier else { return false }
            return bundleIDs.contains(bid)
        }
    }
}
