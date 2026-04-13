# Plan C: 收件箱 UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebuild the inbox UI as an AI butler interface — compact signal bar, expanded action list with AI summary display, hover quick-actions (snooze/dismiss), expandable briefing panel, handled section, undo bar, right-click menu, and menu bar badge sync.

**Architecture:** Rewrite InboxView/InboxRowView/HUDRootView. Add CompactInboxBar for the new three-state compact display. Add snooze/silence to ChatMonitor + InboxBuilder. Add handled items section. Connect menu bar badge.

**Tech Stack:** SwiftUI, AppKit (NSPanel, NSStatusItem)

---

## Tasks

### Task 1: Enhance InboxItem + InboxBuilder with snooze/silence/overdue/replied
### Task 2: Rewrite CompactInboxBar (three visual states)
### Task 3: Rewrite InboxRowView (hover actions, status labels, AI summary)
### Task 4: Add snooze popover + undo bar
### Task 5: Add handled items section
### Task 6: Rewrite expand panel (butler briefing structure with loading)
### Task 7: Right-click context menu
### Task 8: Rewrite InboxView (assemble all components)
### Task 9: Update HUDRootView + PanelState + AppDelegate sizing
### Task 10: Menu bar badge sync + Detail notification bar
### Task 11: Final verification
