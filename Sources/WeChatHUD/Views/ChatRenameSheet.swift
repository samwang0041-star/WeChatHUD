import SwiftUI

/// Name a conversation the user recognises.
///
/// WeChat leaves a large share of groups unnamed; when the app can only show a
/// placeholder, this is how the user replaces it with something meaningful.
/// Members are offered as suggestions because that is usually how a nameless
/// group is recognised in the first place.
struct ChatRenameSheet: View {
    @EnvironmentObject private var monitor: ChatMonitor
    @Environment(\.dismiss) private var dismiss

    let chatUsername: String
    let currentName: String
    var memberNames: [String] = []

    @State private var draftName = ""
    @State private var errorMessage: String?

    private var suggestions: [String] {
        var seen = Set<String>()
        return memberNames.filter { name in
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    private var trimmedDraft: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("给这个会话起个名字")
                    .font(.system(size: 14, weight: .semibold))
                Text("微信里这个群没有名字，助手只能显示成员信息。起个名字后，收件箱和「我答应的事」都会用这个名字。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CompanionClipboardField(
                text: $draftName,
                placeholder: "例如：供应链周会",
                kind: .plain,
                accessibilityLabel: "会话名称",
                onSubmit: save
            )

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("群成员")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    FlowRow(spacing: 6) {
                        ForEach(suggestions, id: \.self) { name in
                            Button(name) { draftName = name }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if monitor.store.chatAlias(for: chatUsername) != nil {
                    Button("恢复微信原名") { clearAlias() }
                        .controlSize(.small)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedDraft.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            // Pre-fill with the alias when one exists; a placeholder or a
            // member-derived label is a starting point, not something the
            // user needs to retype.
            draftName = monitor.store.chatAlias(for: chatUsername) ?? ""
        }
    }

    private func save() {
        guard !trimmedDraft.isEmpty else { return }
        do {
            try monitor.renameChat(chatUsername: chatUsername, displayName: trimmedDraft)
            dismiss()
        } catch {
            errorMessage = "名字没有保存成功，原名称仍保留。请重试。"
        }
    }

    private func clearAlias() {
        do {
            try monitor.clearChatAlias(chatUsername: chatUsername)
            dismiss()
        } catch {
            errorMessage = "没有恢复成微信原名，请重试。"
        }
    }
}

/// Minimal wrapping row — the sheet only needs to lay out a handful of chips.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var usedWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                usedWidth = max(usedWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += rowWidth > 0 ? spacing + size.width : size.width
            rowHeight = max(rowHeight, size.height)
        }
        usedWidth = max(usedWidth, rowWidth)
        return CGSize(width: usedWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
