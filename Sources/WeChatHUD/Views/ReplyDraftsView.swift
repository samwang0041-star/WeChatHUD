import SwiftUI
import AppKit

/// 草稿 master-detail matching 不漏事 figure 04 / 37 / 42.
struct ReplyDraftsView: View {
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var workspaceBadges: WorkspaceBadges
    @FocusState private var editorFocused: Bool
    @State private var drafts: [Draft] = []
    @State private var selectedID: Int64?
    @State private var feedback: String?
    @State private var query = ""
    @State private var pendingContinueDraft: Draft?
    @State private var pendingDeleteDraft: Draft?
    @State private var savedAt: Date?

    struct Draft: Identifiable, Equatable {
        let id: Int64
        let chatUsername: String
        let chatName: String
        var text: String
        let createdAt: Date
        let isComposerOnly: Bool
    }

    private var filteredDrafts: [Draft] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return drafts }
        return drafts.filter { draft in
            selectedID == draft.id || draft.chatName.localizedCaseInsensitiveContains(text) || draft.text.localizedCaseInsensitiveContains(text)
        }
    }

    private var selected: Draft? {
        filteredDrafts.first(where: { $0.id == selectedID }) ?? filteredDrafts.first
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if let feedback {
                Label(feedback, systemImage: feedback.contains("失败") || feedback.contains("无法") ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(feedback.contains("失败") || feedback.contains("无法") ? .orange : CompanionPalette.jade)
                    .padding(.vertical, 8)
            }
            if drafts.isEmpty {
                ContentUnavailableView("还没有回复草稿", systemImage: "square.and.pencil", description: Text("对话里正在写的回复、以及点过「存为草稿」的内容，都会出现在这里。草稿不会自动发送。"))
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if filteredDrafts.isEmpty {
                VStack(spacing: 10) {
                    Text("没有匹配的草稿").font(.system(size: 15, weight: .semibold))
                    Text("当前搜索：\(query)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("清除搜索") { query = "" }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                HSplitView {
                    listPane.frame(minWidth: 260, idealWidth: 320)
                    detailPane.frame(minWidth: 360, idealWidth: 480)
                }
            }
        }
        .frame(maxWidth: 1180)
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .onAppear { load() }
        .onChange(of: workspaceBadges.counts.drafts) { _, _ in load() }
        .onChange(of: drafts) { _, _ in reconcileSelection() }
        .onChange(of: query) { _, _ in reconcileSelection() }
        .onChange(of: pendingContinueDraft != nil || pendingDeleteDraft != nil) { _, open in
            if open { editorFocused = false }
        }
        .companionDialogBackdrop(pendingContinueDraft != nil || pendingDeleteDraft != nil) {
            if let draft = pendingContinueDraft {
                CompanionDialog(title: CompanionProductCopy.draftConflictTitle, onClose: { pendingContinueDraft = nil }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(CompanionProductCopy.draftConflictMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button(CompanionProductCopy.draftKeepCurrent) { pendingContinueDraft = nil }
                            Button(CompanionProductCopy.draftReplaceContinue) {
                                pendingContinueDraft = nil
                                continueReply(with: draft)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(CompanionPalette.jade)
                        }
                    }
                }
            } else if let draft = pendingDeleteDraft {
                CompanionDialog(title: CompanionProductCopy.deleteDraftTitle(name: draft.chatName), onClose: { pendingDeleteDraft = nil }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(CompanionProductCopy.deleteDraftMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("保留") { pendingDeleteDraft = nil }
                            Button("删除", role: .destructive) {
                                pendingDeleteDraft = nil
                                deleteDraft(draft)
                            }
                        }
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索草稿的联系人或内容", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索草稿的联系人或内容")
            if !query.isEmpty {
                Button("清除搜索") { query = "" }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CompanionPalette.jade)
            }
        }
        .padding(10)
        .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(CompanionPalette.border))
        .padding(.bottom, 12)
    }

    private var listPane: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredDrafts) { draft in
                    Button {
                        selectedID = draft.id
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            CompanionAvatar(name: draft.chatName, size: 32)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(draft.chatName).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    if draft.isComposerOnly {
                                        Text("正在写").font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Text(draft.createdAt, format: .dateTime.hour().minute())
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Text(draft.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(10)
                        .background(selected?.id == draft.id ? CompanionPalette.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .leading) {
                            if selected?.id == draft.id {
                                Capsule().fill(CompanionPalette.jade).frame(width: 3).padding(.vertical, 8)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, 10)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selected, let index = drafts.firstIndex(where: { $0.id == selected.id }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    CompanionAvatar(name: selected.chatName, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(selected.chatName) · \(selected.chatUsername.contains("@chatroom") ? "群聊" : "私聊")").font(.system(size: 15, weight: .semibold))
                        Text(selected.isComposerOnly ? "正在写，还没存成草稿" : "未发送").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("删除草稿") { pendingDeleteDraft = selected }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("草稿操作")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("对方原话").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(counterpartQuote(for: selected))
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $drafts[index].text)
                        .font(.system(size: 14))
                        .frame(minHeight: 120)
                        .focused($editorFocused)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("草稿正文")
                        .onChange(of: drafts[index].text) { _, text in
                            persist(drafts[index], text: text)
                        }
                    HStack {
                        Text("\(drafts[index].text.count) / 2000")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(12)
                .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(CompanionPalette.jade.opacity(0.35)))

                HStack {
                    if let savedAt {
                        Label("修改已保存 · \(savedAt.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(CompanionPalette.jade)
                    }
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selected.text, forType: .string)
                        feedback = "回复已复制，发送前请核对收件人。"
                    }
                    Button("删除草稿") { pendingDeleteDraft = selected }
                    Button("查看对话") {
                        panelState.showChatDetail(chatUsername: selected.chatUsername, chatName: selected.chatName)
                    }
                    Button("继续回复") { requestContinueReply(selected) }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("继续回复会打开对话，发送前再次确认。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 16)
            .padding(.vertical, 8)
        }
    }

    private func counterpartQuote(for draft: Draft) -> String {
        if let item = monitor.inboxItems.first(where: { $0.chatUsername == draft.chatUsername }) {
            return item.preview
        }
        return "这条草稿还没有对应的对方原话。"
    }

    private func persist(_ draft: Draft, text: String) {
        do {
            if draft.isComposerOnly {
                try store.setSetting("composer_draft:\(draft.chatUsername)", value: text)
                monitor.composerDraftEdits[draft.chatUsername] = text
            } else {
                try store.updateDraft(id: draft.id, text: text)
                monitor.unsavedReplyDraftEdits.removeValue(forKey: draft.id)
            }
            savedAt = Date()
            feedback = nil
        } catch {
            if draft.isComposerOnly {
                monitor.composerDraftEdits[draft.chatUsername] = text
            } else {
                monitor.unsavedReplyDraftEdits[draft.id] = text
            }
            feedback = "自动保存失败，文字仍保留在当前应用中，请重试。"
        }
    }

    private func requestContinueReply(_ draft: Draft) {
        let existing = monitor.composerDraftEdits[draft.chatUsername]
            ?? store.getSetting("composer_draft:\(draft.chatUsername)")
            ?? ""
        let hasDifferentContent = !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && existing != draft.text
        if hasDifferentContent {
            pendingContinueDraft = draft
        } else {
            continueReply(with: draft)
        }
    }

    private func continueReply(with draft: Draft) {
        do {
            try store.setSetting("composer_draft:\(draft.chatUsername)", value: draft.text)
            monitor.composerDraftEdits[draft.chatUsername] = draft.text
            panelState.requestReplyDraftContinuation(chatUsername: draft.chatUsername, text: draft.text, savedDraftID: draft.id)
            feedback = "草稿已带入回复框，请核对后发送。"
            panelState.showChatDetail(chatUsername: draft.chatUsername, chatName: draft.chatName)
        } catch {
            feedback = "无法带入回复框，原有内容已保留，请重试。"
        }
    }

    private func deleteDraft(_ draft: Draft) {
        do {
            if draft.isComposerOnly {
                try store.clearComposerDraft(chatUsername: draft.chatUsername)
                monitor.composerDraftEdits[draft.chatUsername] = ""
            } else {
                try store.deleteDraft(id: draft.id)
                monitor.unsavedReplyDraftEdits.removeValue(forKey: draft.id)
            }
            drafts.removeAll { $0.id == draft.id }
            if selectedID == draft.id { selectedID = drafts.first?.id }
            monitor.refreshWorkspaceChrome()
            feedback = "草稿已删除。"
        } catch {
            feedback = "草稿删除失败，原草稿仍保留，请重试。"
        }
    }

    private func reconcileSelection() {
        if let selectedID, filteredDrafts.contains(where: { $0.id == selectedID }) { return }
        selectedID = filteredDrafts.first?.id
    }

    private func load() {
        let rows = store.loadWorkspaceDrafts()
        if rows.isEmpty && !monitor.unsavedReplyDraftEdits.isEmpty {
            feedback = "本地草稿暂不可读，已保留当前未保存的文字。请稍后重试。"
            return
        }
        drafts = rows.map { row in
            let text = row.isComposerOnly
                ? (monitor.composerDraftEdits[row.chatUsername] ?? row.text)
                : (monitor.unsavedReplyDraftEdits[row.id] ?? row.text)
            return Draft(
                id: row.id,
                chatUsername: row.chatUsername,
                chatName: row.chatName,
                text: text,
                createdAt: row.createdAt,
                isComposerOnly: row.isComposerOnly
            )
        }
        if selectedID == nil { selectedID = drafts.first?.id }
    }
}
