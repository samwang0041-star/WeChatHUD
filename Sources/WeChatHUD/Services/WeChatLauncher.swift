import AppKit
import ApplicationServices
import CoreGraphics

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

    // Virtual key codes (ANSI layout). These are hardware codes that
    // don't change with keyboard layout — good for our use case since
    // we're typing modifier+letter, not text.
    private static let kVK_ANSI_A: CGKeyCode = 0x00
    private static let kVK_ANSI_F: CGKeyCode = 0x03
    private static let kVK_ANSI_V: CGKeyCode = 0x09
    private static let kVK_Return: CGKeyCode = 0x24
    private static let kVK_Escape: CGKeyCode = 0x35

    /// Bring WeChat forward, populate its search field with `chatName`,
    /// and submit — opening that conversation. Silently no-ops if WeChat
    /// isn't running (we don't try to launch it; the user typically
    /// keeps it running anyway).
    static func openChat(named chatName: String) {
        log("openChat called: \(chatName)")

        guard let app = runningWeChat() else {
            log("WeChat not running — abort")
            NSSound.beep()
            return
        }
        log("WeChat found: \(app.bundleIdentifier ?? "?") pid=\(app.processIdentifier)")

        // Accessibility permission check + prompt. First call surfaces
        // the system dialog; caller retries after the user grants.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        log("AXIsProcessTrusted = \(trusted)")
        if !trusted {
            log("Accessibility not granted — prompt surfaced, caller should retry")
            return
        }

        // Stash clipboard upfront so even if activation fails we can
        // still restore it. (We also prime the pasteboard with the
        // target name so Cmd+V will paste correctly.)
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(chatName, forType: .string)

        // Activate WeChat via NSWorkspace — the only activation path
        // that works from an LSUIElement accessory. `activate(options:)`
        // on NSRunningApplication is silently ignored from our process.
        activateWeChat(app: app) { activated in
            guard activated else {
                log("activation failed; restoring clipboard")
                restoreClipboard(saved: saved)
                return
            }

            waitUntilFrontmost(app: app) { isFront in
                guard isFront else {
                    log("WeChat never became frontmost; aborting")
                    restoreClipboard(saved: saved)
                    return
                }
                // Small settle pass so the AX tree has the freshest
                // session list before we walk it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    tryAXOpenOrFallback(
                        app: app,
                        chatName: chatName,
                        savedClipboard: saved
                    )
                }
            }
        }
    }

    /// Primary path: use the Accessibility API to walk WeChat's UI
    /// tree. Two-step strategy (ported from BiboyQG/WeChat-MCP):
    ///
    /// 1. Look for a session element in the visible sidebar
    ///    (`session_item_<name>` identifier). Click it if found.
    /// 2. Otherwise, use AX to focus the search field, type the chat
    ///    name via clipboard paste (search field is guaranteed focused
    ///    via `AXUIElementPerformAction(raise)`), then walk the
    ///    `search_list` AX element looking for an exact-match entry
    ///    under the Contacts or Group Chats section header, and
    ///    click it.
    ///
    /// Reference:
    /// https://github.com/BiboyQG/WeChat-MCP/blob/master/src/wechat_mcp/wechat_accessibility.py
    private static func tryAXOpenOrFallback(
        app: NSRunningApplication,
        chatName: String,
        savedClipboard: String?
    ) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // --- Step 0: already on this chat? ---
        //
        // If WeChat is already showing the target chat, clicking its
        // session_item_ in the sidebar (which is the currently-
        // selected row) would toggle the selection off and **close
        // the chat view**. Detect this case by reading the current
        // chat title from the AX tree and skip straight to focusing
        // the message input.
        if let currentTitle = currentChatTitle(in: axApp) {
            log("AX: current chat title = \(currentTitle)")
            if normalizeChatTitle(currentTitle) == normalizeChatTitle(chatName) {
                log("AX: already on target chat; skipping open, just focusing input")
                focusMessageInput(in: axApp, savedClipboard: savedClipboard)
                return
            }
        }

        // --- Step 1: direct sidebar click if visible ---
        if let element = findSessionItem(in: axApp, chatName: chatName) {
            log("AX: found session_item_\(chatName), clicking center")
            if clickAXElementCenter(element) {
                log("AX click posted")
                focusMessageInput(in: axApp, savedClipboard: savedClipboard)
                return
            }
        }
        log("AX: not in sidebar, trying AX search field")

        // --- Step 2: AX search field + results click ---
        guard let searchField = findSearchField(in: axApp) else {
            log("AX: search field not found, giving up")
            restoreClipboard(saved: savedClipboard)
            return
        }
        log("AX: found search field; clicking to activate")

        // Physical click on the search field center — more reliable
        // than `kAXRaiseAction` alone. `AXUIElementPerformAction(raise)`
        // sometimes gives focus without actually opening WeChat's
        // search popover, which is what we observed between clicks
        // #1 (popover open) and #2 (popover never appeared).
        _ = clickAXElementCenter(searchField)

        // Settle delay after the click; then paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            // Clear any existing value via AX as a best-effort guard
            // against stale text in the field from a prior click.
            _ = AXUIElementSetAttributeValue(searchField, kAXValueAttribute as CFString, "" as CFTypeRef)

            log("AX: Cmd+A on search field")
            postCmdKey(kVK_ANSI_A)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                log("AX: Cmd+V on search field")
                postCmdKey(kVK_ANSI_V)

                // Poll search_list instead of a hard-coded wait.
                // WeChat populates the popover asynchronously and the
                // latency varies with visual state.
                pollForSearchListAndSelect(
                    axApp: axApp,
                    chatName: chatName,
                    savedClipboard: savedClipboard,
                    attempts: 12,
                    interval: 0.1
                )
            }
        }
    }

    private static func pollForSearchListAndSelect(
        axApp: AXUIElement,
        chatName: String,
        savedClipboard: String?,
        attempts: Int,
        interval: TimeInterval
    ) {
        guard attempts > 0 else {
            log("AX: search_item_\(chatName) never appeared, giving up")
            restoreClipboard(saved: savedClipboard)
            return
        }

        // WeChat's search_list element exists even in the "recent
        // searches" state, so we can't stop polling just because the
        // list has entries — we have to keep polling until our
        // specific `search_item_<chatName>` shows up (WeChat populates
        // results asynchronously after the text-change event).
        if let match = findSearchItem(in: axApp, chatName: chatName) {
            log("AX: found search_item_\(chatName) after \((12 - attempts + 1) * Int(interval * 1000))ms polling, clicking")
            _ = clickAXElementCenter(match)
            focusMessageInput(in: axApp, savedClipboard: savedClipboard)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            pollForSearchListAndSelect(
                axApp: axApp,
                chatName: chatName,
                savedClipboard: savedClipboard,
                attempts: attempts - 1,
                interval: interval
            )
        }
    }

    /// Find the search-result element for a given chat name. Mirror of
    /// `findSessionItem` but looks for the `search_item_` prefix used
    /// inside `search_list`.
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
    private static func focusMessageInput(
        in axApp: AXUIElement,
        savedClipboard: String?,
        attemptsLeft: Int = 10
    ) {
        // Small settle so the chat view has a chance to render before
        // we go hunting for its input field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if let input = findMessageInput(in: axApp) {
                log("AX: focusing message input")
                // Prefer AX-level focus (no cursor warp, no racy click).
                _ = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                // Belt-and-braces: also click the center. Some WeChat
                // builds ignore the AX focus write and need a real
                // click event to transfer first-responder.
                _ = clickAXElementCenter(input)
                restoreClipboard(saved: savedClipboard)
                return
            }
            if attemptsLeft > 0 {
                focusMessageInput(in: axApp, savedClipboard: savedClipboard, attemptsLeft: attemptsLeft - 1)
            } else {
                log("AX: message input not found — aborting focus step")
                restoreClipboard(saved: savedClipboard)
            }
        }
    }

    /// Heuristic: WeChat's chat view has exactly one `AXTextArea`
    /// inside it (the message input). The sidebar has another one
    /// with title "Search"/"搜索" — we skip that. We also exclude
    /// elements with zero size since the search field sometimes
    /// lingers hidden in the tree.
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

    private static func restoreClipboard(saved: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let saved = saved {
            pb.setString(saved, forType: .string)
        }
        log("clipboard restored")
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

    private static func runningWeChat() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard let bid = app.bundleIdentifier else { return false }
            return bundleIDs.contains(bid)
        }
    }
}
