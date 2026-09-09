import AppKit
import SwiftUI

/// Clipboard helpers for AI connection fields. Right-click paste sanitizes
/// a URL, key, or model name so a copied browser line still becomes a usable value.
enum CompanionClipboard {
    enum Kind: Equatable {
        case url
        case secret
        case model
        case plain

        var replacesEntireFieldOnPaste: Bool {
            switch self {
            case .url, .secret, .model: return true
            case .plain: return false
            }
        }
    }

    enum Action: Equatable {
        case paste
        case copy
        case cut
    }

    struct MenuItem: Equatable {
        let title: String
        let action: Action
        let enabled: Bool
    }

    static func read() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func menuItems(fieldText: String, clipboard: String?, writable: Bool, secure: Bool = false) -> [MenuItem] {
        let hasField = !fieldText.isEmpty
        let hasClip = !(clipboard ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var items: [MenuItem] = []
        if writable {
            items.append(MenuItem(title: "粘贴", action: .paste, enabled: hasClip))
        }
        if !secure {
            items.append(MenuItem(title: "复制", action: .copy, enabled: hasField))
            if writable {
                items.append(MenuItem(title: "剪切", action: .cut, enabled: hasField))
            }
        }
        return items
    }

    static func apply(_ action: Action, fieldText: String, clipboard: String?, kind: Kind) -> String {
        switch action {
        case .copy:
            return fieldText
        case .cut:
            return ""
        case .paste:
            return sanitizedPaste(clipboard ?? "", kind: kind)
        }
    }

    static func sanitizedPaste(_ raw: String, kind: Kind) -> String {
        let text = unwrapQuotes(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        switch kind {
        case .url:
            if let url = firstURL(in: text) { return url }
            return firstLine(text)
        case .secret:
            return extractSecret(text)
        case .model:
            return firstLine(text)
        case .plain:
            return text
        }
    }

    private static func unwrapQuotes(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        let first = raw.first
        let last = raw.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return unwrapQuotes(String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return raw
    }

    private static func firstLine(_ raw: String) -> String {
        raw.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? raw
    }

    static func firstURL(in raw: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = detector.firstMatch(in: raw, options: [], range: range),
              let swiftRange = Range(match.range, in: raw) else {
            return nil
        }
        return String(raw[swiftRange])
    }

    private static func extractSecret(_ raw: String) -> String {
        let lines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { unwrapQuotes(String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        let tokens = lines.flatMap { line -> [String] in
            var text = line
            if text.lowercased().hasPrefix("bearer ") {
                text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return text.split { $0.isWhitespace || $0 == "=" || $0 == ":" }.map(String.init)
        }
        if let preferred = tokens.first(where: { looksLikePreferredSecret($0) }) {
            return preferred
        }
        if let token = tokens.first(where: { looksLikeSecret($0) }) {
            return token
        }
        return firstLine(raw)
    }

    private static let genericSecretLabels: Set<String> = [
        "password", "passwd", "secret", "token", "apikey", "api", "key",
        "密码", "密钥", "访问凭据"
    ]

    private static func looksLikePreferredSecret(_ token: String) -> Bool {
        let lower = token.lowercased()
        return lower.hasPrefix("sk-")
            || lower.hasPrefix("ghp_")
            || lower.hasPrefix("github_pat_")
            || lower.hasPrefix("gho_")
    }

    private static func looksLikeSecret(_ token: String) -> Bool {
        let folded = token.lowercased().replacingOccurrences(of: " ", with: "")
        if genericSecretLabels.contains(folded) { return false }
        return token.count >= 16 && !token.contains("://")
    }
}

/// Selectable / editable AppKit field whose right-click menu always offers
/// copy and a sanitized paste. SwiftUI `TextField` in this window often cannot.
struct CompanionClipboardField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var kind: CompanionClipboard.Kind = .plain
    var writable: Bool = true
    var secure: Bool = false
    var monospaced: Bool = false
    var accessibilityLabel: String
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField(string: text) : NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.isEditable = writable
        field.isSelectable = true
        field.focusRingType = .default
        field.drawsBackground = true
        field.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            : NSFont.systemFont(ofSize: 13)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(accessibilityLabel)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submitted(_:))
        context.coordinator.attach(to: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.isEditable = writable
        field.isSelectable = true
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, NSMenuDelegate {
        var parent: CompanionClipboardField
        private weak var field: NSTextField?
        private var pasteItem: NSMenuItem?
        private var copyItem: NSMenuItem?
        private var cutItem: NSMenuItem?

        init(_ parent: CompanionClipboardField) {
            self.parent = parent
        }

        func attach(to field: NSTextField) {
            self.field = field
            let menu = NSMenu()
            menu.delegate = self
            let copy = NSMenuItem(title: "复制", action: #selector(copySmart(_:)), keyEquivalent: "c")
            copy.target = self
            if parent.writable {
                let paste = NSMenuItem(title: "粘贴", action: #selector(pasteSmart(_:)), keyEquivalent: "v")
                paste.target = self
                menu.addItem(paste)
                pasteItem = paste
            }
            if !parent.secure {
                menu.addItem(copy)
                copyItem = copy
                if parent.writable {
                    let cut = NSMenuItem(title: "剪切", action: #selector(cutSmart(_:)), keyEquivalent: "x")
                    cut.target = self
                    menu.addItem(cut)
                    cutItem = cut
                }
            }
            field.menu = menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            let items = CompanionClipboard.menuItems(
                fieldText: field?.stringValue ?? parent.text,
                clipboard: CompanionClipboard.read(),
                writable: parent.writable,
                secure: parent.secure
            )
            pasteItem?.isEnabled = items.first(where: { $0.action == .paste })?.enabled ?? false
            copyItem?.isEnabled = items.first(where: { $0.action == .copy })?.enabled ?? false
            cutItem?.isEnabled = items.first(where: { $0.action == .cut })?.enabled ?? false
            _ = menu
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSTextView.paste(_:))
                || commandSelector == #selector(NSTextView.pasteAsPlainText(_:)) {
                pasteSmart(nil)
                return true
            }
            return false
        }

        @objc func pasteSmart(_ sender: Any?) {
            let next = CompanionClipboard.apply(
                .paste,
                fieldText: field?.stringValue ?? parent.text,
                clipboard: CompanionClipboard.read(),
                kind: parent.kind
            )
            apply(next)
        }

        @objc func copySmart(_ sender: Any?) {
            let value = field?.stringValue ?? parent.text
            guard !value.isEmpty else { return }
            CompanionClipboard.write(value)
        }

        @objc func cutSmart(_ sender: Any?) {
            copySmart(sender)
            apply("")
        }

        @objc func submitted(_ sender: Any?) {
            parent.onSubmit?()
        }

        private func apply(_ value: String) {
            field?.stringValue = value
            parent.text = value
        }
    }
}

/// Read-only copy surface for connection results and preset addresses.
struct CompanionCopyableText: View {
    let text: String
    var monospaced: Bool = false
    var lineLimit: Int? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 13, design: monospaced ? .monospaced : .default))
            .textSelection(.enabled)
            .lineLimit(lineLimit)
            .truncationMode(.middle)
            .contextMenu {
                Button("复制") { CompanionClipboard.write(text) }
                    .disabled(text.isEmpty)
            }
    }
}
