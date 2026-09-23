import XCTest
@testable import WeChatHUD

/// Source-scan gates for the shared motion/visual/copy language.
///
/// These drive the shipped files, not a re-implementation: a new unguarded
/// `withAnimation(` in Views, a 30pt page title, or a forbidden chrome word
/// in customer-facing labels fails here.
final class ChromeMotionHygieneTests: XCTestCase {

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
    }

    private func swiftFiles(under relative: String) throws -> [(name: String, text: String)] {
        let root = sourcesRoot().appendingPathComponent(relative)
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        XCTAssertFalse(files.isEmpty, "no Swift files under \(relative)")
        return try files.map { (name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testViewsDoNotCallUnguardedWithAnimation() throws {
        for file in try swiftFiles(under: "Views") {
            if file.name == "CompanionMotion.swift" {
                XCTAssertTrue(
                    file.text.contains("withAnimation(animation, body)"),
                    "the reduceMotion wrapper itself must be the only withAnimation call site"
                )
                let extras = file.text.components(separatedBy: "withAnimation(").count - 2
                XCTAssertEqual(extras, 0, "CompanionMotion.swift grew another withAnimation(")
                continue
            }
            for (index, line) in file.text.components(separatedBy: .newlines).enumerated() {
                guard line.contains("withAnimation(") else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                XCTAssertTrue(
                    trimmed.contains("withAnimation(nil)"),
                    "\(file.name):\(index + 1) calls withAnimation outside the reduceMotion wrapper: \(trimmed)"
                )
            }
        }
    }

    func testIslandStateSwapUsesExplicitNilAnimation() throws {
        let root = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/HUDRootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(root.contains(".animation(nil, value: panelState.presentedState)"))
    }

    func testAttachedPanelDoesNotTrapWhenTheIUOIsStillNil() {
        let app = AppDelegate()
        XCTAssertNil(app.attachedPanel)
    }

    func testIslandPillsUseTheSharedPressScale() throws {
        let source = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/IslandStyle.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("CompanionMotion.pressScale"))
        XCTAssertTrue(source.contains("CompanionMotion.press()"))
        XCTAssertTrue(source.contains("struct IslandInboxRowButtonStyle"))
        XCTAssertTrue(source.contains("IslandInk.hoverPressed"))

        let compact = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CompactInboxBar.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(compact.contains("IslandRowButtonStyle(paintsHover: false)"))
        XCTAssertFalse(compact.contains("CompanionPressStyle()"))
        XCTAssertTrue(compact.contains("if CompanionMotion.reduceMotion"))
        XCTAssertTrue(compact.contains("pillsVisible = peeking"))
        XCTAssertTrue(compact.contains("CompanionMotion.reduceMotion ? 0"))

        let banner = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/NotificationBannerView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(banner.contains("IslandIconButtonStyle()"))
        XCTAssertFalse(banner.contains("CompanionPressStyle()"))

        let toast = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/HUDRootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(toast.contains("IslandIconButtonStyle()"))
        XCTAssertTrue(toast.contains("IslandRowButtonStyle()"))
        XCTAssertFalse(toast.contains("CompanionPressStyle()"))

        let inboxRow = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/InboxRowView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(inboxRow.contains("CompanionPressStyle()"))
        XCTAssertTrue(inboxRow.contains("CompanionClipboard.write"))
        XCTAssertTrue(inboxRow.contains("CompanionInteractionCopy.copied"))
        XCTAssertTrue(inboxRow.contains("CompanionInteractionCopy.copyFailed"))
        XCTAssertFalse(inboxRow.contains("NSPasteboard.general.setString"))

        let briefing = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/GroupContextBriefingButton.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(briefing.contains("IslandPillButtonStyle(emphasized: true)"))
        XCTAssertTrue(briefing.contains("IslandPillButtonStyle(emphasized: showSnooze)"))
        XCTAssertFalse(briefing.contains("CompanionPressStyle()"))

        let actions = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/ActionPanelView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(actions.contains("IslandPillButtonStyle(emphasized: true)"))
        XCTAssertTrue(actions.contains("IslandInboxRowButtonStyle("))
        XCTAssertFalse(actions.contains("CompanionPressStyle()"))

        let detail = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/DetailPanelView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(detail.contains("IslandIconButtonStyle()"))
        XCTAssertTrue(detail.contains("IslandRowButtonStyle()"))
        XCTAssertTrue(detail.contains("IslandInboxRowButtonStyle("))
        XCTAssertFalse(detail.contains("CompanionPressStyle()"))
    }

    func testViewsDoNotUseEaseInOnUI() throws {
        for file in try swiftFiles(under: "Views") {
            for (index, line) in file.text.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                let withoutInOut = trimmed.replacingOccurrences(of: "easeInOut", with: "")
                XCTAssertFalse(
                    withoutInOut.contains("CompanionMotion.easeIn")
                        || withoutInOut.contains(".easeIn("),
                    "\(file.name):\(index + 1) uses ease-in on UI: \(trimmed)"
                )
            }
        }
    }

    func testViewsDoNotHardcodeMotionDurations() throws {
        for file in try swiftFiles(under: "Views") {
            if file.name == "CompanionMotion.swift" { continue }
            for (index, line) in file.text.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                XCTAssertFalse(
                    trimmed.contains("CompanionMotion.ease(0")
                        || trimmed.contains("CompanionMotion.easeOut(0"),
                    "\(file.name):\(index + 1) hardcodes a motion duration: \(trimmed)"
                )
            }
        }
    }

    func testViewsDoNotInventAThirdScale() throws {
        for file in try swiftFiles(under: "Views") {
            for (index, line) in file.text.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                if file.name == "CompanionMotion.swift" {
                    continue
                }
                if file.name == "CompanionStyle.swift" {
                    XCTAssertFalse(
                        trimmed.contains("scale(scale: 0.98"),
                        "\(file.name):\(index + 1) should use companionStatusReveal, not a second 0.98: \(trimmed)"
                    )
                    continue
                }
                XCTAssertFalse(
                    trimmed.contains("scale(scale:"),
                    "\(file.name):\(index + 1) invented a scale token: \(trimmed)"
                )
            }
        }
        let dialog = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CompanionStyle.swift"),
            encoding: .utf8
        )
        // The dialog's 0.95 scale lives in the token file with the rest; the
        // call site must route through it rather than inline a third value.
        XCTAssertTrue(dialog.contains(".transition(.companionDialogReveal)"))
        let hud = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/HUDRootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(hud.contains(".transition(.islandDetailReveal)"))
        XCTAssertFalse(hud.contains("scale(scale: 0.95"))
    }

    func testViewsDoNotCallSystemDefaultAnimation() throws {
        for file in try swiftFiles(under: "Views") {
            if file.name == "CompanionMotion.swift" { continue }
            XCTAssertFalse(
                file.text.contains("CompanionMotion.systemDefault"),
                "\(file.name) still uses systemDefault; pick ease/pageChange/nil"
            )
        }
    }

    func testUndoBarUsesAsymmetricEnterAndExit() throws {
        let source = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/InboxView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("CompanionMotion.enter()"))
        XCTAssertTrue(source.contains("CompanionMotion.exit()"))
        XCTAssertFalse(source.contains("CompanionMotion.easeIn"))
        XCTAssertTrue(source.contains(".transition(.islandDetailReveal)"))
        XCTAssertFalse(
            source.contains(".move(edge:"),
            "island undo bar must not slide on a layout edge; that fights the frame spring and leaves a different edge than the toast"
        )
    }

    func testPriorityPulseUsesTheSharedPulseToken() throws {
        let source = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/InboxRowView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("CompanionMotion.pulse()"))
        XCTAssertFalse(source.contains("easeOut(1.4)"))
        XCTAssertFalse(source.contains("autoreverses: false"))
    }

    func testToastWindowUsesEnterExitFamily() throws {
        let source = try String(
            contentsOf: sourcesRoot().appendingPathComponent("App/AppDelegate.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("CompanionMotion.toastWindowAction"))
        XCTAssertTrue(source.contains("CompanionMotion.enterDuration"))
        XCTAssertTrue(source.contains("CompanionMotion.exitDuration"))
        XCTAssertTrue(source.contains("CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)"))
        XCTAssertTrue(source.contains("toastCollapsing = true"))
        XCTAssertTrue(source.contains("toastCollapsing = false"))

        let toast = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/HUDRootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(toast.contains("toastCollapsing"))
        XCTAssertTrue(toast.contains("CompanionMotion.exit()"))
        XCTAssertTrue(toast.contains("anchor: .top"))

        let glow = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/IslandGlowLayer.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(glow.contains("CompanionMotion.hoverDuration"))
        XCTAssertFalse(glow.contains("CompanionMotion.enterDuration"))
    }

    func testIslandPanelCoupledRowsUseTheMorphSpring() throws {
        let island = [
            "Views/InboxView.swift",
            "Views/InboxRowView.swift",
            "Views/NotificationBannerView.swift",
            "Views/GroupContextBriefingButton.swift",
        ]
        for relative in island {
            let source = try String(
                contentsOf: sourcesRoot().appendingPathComponent(relative),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("islandRowExpand"), "\(relative) lost islandRowExpand")
            XCTAssertFalse(
                source.contains("CompanionMotion.rowExpand()"),
                "\(relative) still uses workspace rowExpand on a panel-coupled surface"
            )
        }
        let workspace = [
            "Views/AssistantTodayView.swift",
            "Views/MissedReplyFeed.swift",
            "Views/CommitmentTabView.swift",
            "Views/DiscussionWorkspaceView.swift",
        ]
        for relative in workspace {
            let source = try String(
                contentsOf: sourcesRoot().appendingPathComponent(relative),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("CompanionMotion.rowExpand()"), "\(relative) lost workspace rowExpand")
            XCTAssertFalse(source.contains("islandRowExpand"), "\(relative) should not use the island morph spring")
        }
    }

    func testDialogAndIslandDisclosuresDoNotSnap() throws {
        let dialog = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CompanionStyle.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(dialog.contains(".animation(CompanionMotion.dialog(), value: presented)"))
        XCTAssertTrue(dialog.contains(".transition(.companionDialogReveal)"))
        let dialogMotionSource = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CompanionMotion.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            dialogMotionSource.contains("static var companionDialogReveal: AnyTransition"),
            "dialog reveal token went missing — dialogs would snap on screen"
        )
        XCTAssertTrue(
            dialogMotionSource.contains(".scale(scale: 0.95)"),
            "companionDialogReveal must keep its physical entry scale"
        )
        XCTAssertFalse(dialog.contains("withMotion(CompanionMotion.pageChange()) { action() }"))
        XCTAssertTrue(dialog.contains("Button(action: action)"))
        XCTAssertTrue(dialog.contains("companionAnimation(CompanionMotion.hover(), value: selected)"))

        let inbox = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/InboxView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(inbox.contains("withMotion(CompanionMotion.islandRowExpand()) { showAllPassiveUpdates.toggle() }"))
        XCTAssertTrue(inbox.contains("withMotion(CompanionMotion.islandRowExpand()) { panelState.islandSurface = .tasks }"))
        XCTAssertTrue(inbox.contains("Button {\n                        scope = value"))
        XCTAssertTrue(inbox.contains("companionAnimation(CompanionMotion.islandRowExpand(), value: showHandled)"))

        let banner = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/NotificationBannerView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(banner.contains(".transition(.islandDetailReveal)"))
        XCTAssertTrue(banner.contains("withMotion(CompanionMotion.islandRowExpand()) { showSnooze.toggle() }"))

        XCTAssertTrue(banner.contains("正在保存稍后提醒"))

        let briefing = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/GroupContextBriefingButton.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(briefing.contains("正在保存稍后提醒"))

        XCTAssertTrue(briefing.contains("正在重试…"))
        XCTAssertTrue(briefing.contains("正在重新整理这段群聊"))

        let onboarding = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/OnboardingView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(onboarding.contains("companionAnimation(CompanionMotion.pageChange(), value: step)"))
        XCTAssertTrue(onboarding.contains("goForward(animated: false)"))
        XCTAssertTrue(onboarding.contains("withMotion(animated ? CompanionMotion.pageChange() : nil)"))

        let tasks = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/DiscussionWorkspaceView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(tasks.contains("companionAnimation(CompanionMotion.pageChange(), value: showHistory)"))

        let connection = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/WeChatConnectionSetupView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(connection.contains("companionAnimation(CompanionMotion.drawer(), value: showAccounts)"))
        XCTAssertTrue(connection.contains("CompanionRowPressStyle()"))

        let missed = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/MissedReplyFeed.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(missed.contains("companionAnimation(CompanionMotion.drawer(), value: window)"))

        let today = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/AssistantTodayView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(today.contains("companionAnimation(CompanionMotion.pageChange(), value: showMissed)"))
        XCTAssertFalse(today.contains("companionAnimation(CompanionMotion.pageChange(), value: showUpdates)"))
        XCTAssertFalse(today.contains("withMotion(CompanionMotion.pageChange()) { showUpdates.toggle() }"))
        XCTAssertTrue(today.contains("CompanionRowPressStyle()"))
        guard let missed = today.range(of: "if showMissed {") else {
            return XCTFail("today lost the missed-replies pane")
        }
        XCTAssertTrue(
            String(today[missed.lowerBound...].prefix(420)).contains(".transition(.companionStatusReveal)"),
            "today missed/list swap must transition, not snap"
        )

        let setup = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CompanionSetupCard.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(setup.contains("companionAnimation(CompanionMotion.ease(), value: aiSetupExpanded)"))
        XCTAssertTrue(setup.contains("CompanionRowPressStyle()"))

        let models = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/AISettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(models.contains("companionAnimation(CompanionMotion.drawer(), value: isExpanded)"))
        XCTAssertTrue(models.contains("withMotion(nil) { isExpanded = false }"))
        XCTAssertTrue(models.contains("CompanionRowPressStyle()"))
        XCTAssertFalse(models.contains("onTapGesture"))
        XCTAssertTrue(models.contains("CompanionCopyableText(text: summary, weight: .medium)"))
        XCTAssertFalse(models.contains("CompanionClipboard.write(summary)"))

        let copyable = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/CompanionClipboard.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(copyable.contains("let ok = CompanionClipboard.write(text)"))
        XCTAssertTrue(copyable.contains("CompanionInteractionCopy.copied"))
        XCTAssertTrue(copyable.contains("CompanionInteractionCopy.copyFailed"))
        XCTAssertTrue(copyable.contains(".transition(.companionStatusReveal)"))

        let motion = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CompanionMotion.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(motion.contains("static var companionStatusReveal"))
        XCTAssertTrue(connection.contains(".transition(.companionStatusReveal)"))
    }

    func testCustomDisclosureContentAndIslandGlyphsDoNotSnap() throws {
        let commitments = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CommitmentTabView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(commitments.contains(
            ".background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))\n                .transition(.companionStatusReveal)"
        ))

        let radar = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Analytics/InsightRadarSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(radar.contains(".transition(.companionStatusReveal)"))

        let connection = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/WeChatConnectionSetupView.swift"),
            encoding: .utf8
        )
        guard let accountsStart = connection.range(of: "if showAccounts {") else {
            return XCTFail("connection setup lost the account picker")
        }
        let accountsWindow = String(connection[accountsStart.lowerBound...].prefix(900))
        XCTAssertTrue(accountsWindow.contains(".transition(.companionStatusReveal)"))

        let inbox = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/InboxView.swift"),
            encoding: .utf8
        )
        guard let gear = inbox.range(of: "gearshape.fill") else {
            return XCTFail("island header lost the settings glyph")
        }
        XCTAssertTrue(String(inbox[gear.lowerBound...].prefix(280)).contains(".frame(width: 22, height: 22)"))

        let autopilot = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/AutopilotIndicator.swift"),
            encoding: .utf8
        )
       XCTAssertTrue(autopilot.contains(".frame(minWidth: 22, minHeight: 22)"))
        XCTAssertTrue(autopilot.contains("AutopilotStopCopy.stopping"))
        XCTAssertTrue(autopilot.contains("elapsedLabel"))
        XCTAssertFalse(autopilot.contains(")s\""))
        XCTAssertFalse(autopilot.contains(".disabled(stopping)\n"))
        XCTAssertFalse(autopilot.contains(".popover("), "autopilot controls must stay in the island AX tree")
        XCTAssertTrue(inbox.contains("AutopilotPopoverView"))
        XCTAssertTrue(autopilot.contains("待确认回复"))
        XCTAssertFalse(autopilot.contains("autopilotDashboard"))
        XCTAssertFalse(autopilot.contains("浮窗内查看"))
        XCTAssertTrue(autopilot.contains("IslandInboxRowButtonStyle("))
        XCTAssertFalse(autopilot.contains("CompanionPressStyle()"))
   }

    /// Scrolling surfaces fade into their fixed chrome instead of being cut
    /// by it (apple-design scroll edges). Both hosts must route through the
    /// shared wash with their own ground colour.
    func testScrollingSurfacesFadeIntoTheirChrome() throws {
        let workspace = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/WorkspacePageLayout.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            workspace.contains(".companionScrollEdgeFade(WorkspacePage.ground)"),
            "workspace pages must fade into the header / status bar"
        )
        let conversation = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/ConversationDetailView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            conversation.contains(".companionScrollEdgeFade(CompanionPalette.island)"),
            "the transcript must fade into the header / composer"
        )
        // The fade may be applied at exactly two hosts and defined once —
        // a scattered definition invites a third, untested variant.
        let material = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CompanionMaterial.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            material.contains("func companionScrollEdgeFade"),
            "the wash lives in the material layer with the rest of the light language"
        )
        let total = [workspace, conversation, material]
            .joined()
            .components(separatedBy: ".companionScrollEdgeFade(")
            .count - 1
        XCTAssertEqual(total, 2, "exactly the workspace body and the transcript take the wash")
    }

    /// Pointing at a transient surface (undo bar, toast) is reading it — the
    /// auto-dismiss clock must hold while the pointer is on it (Sonner's
    /// hover rule), or the user loses the undo mid-sentence. Keyboard focus
    /// holds it through the same combined check, so the two cannot cut each
    /// other's holds short.
    func testTransientSurfacesHoldTheirClockUnderThePointer() throws {
        let inbox = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/InboxView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            inbox.contains("applyUndoClockHold()"),
            "the undo bar must freeze its window through one combined hold rule"
        )
        XCTAssertTrue(
            inbox.contains("undoHovering || undoFocused"),
            "pointer and keyboard focus share the hold — either keeps the undo alive"
        )
        let hud = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/HUDRootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            hud.contains("setToastCountdownSuspended(toastHovering || toastUndoFocused)"),
            "the toast carries the snooze undo — hover and focus both hold its clock"
        )
    }

    func testEmptyAndErrorStatesOfferTheNextAction() throws {
        let discussion = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/DiscussionWorkspaceView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(discussion.contains("Button(\"切到「全记」\")"))
        XCTAssertTrue(discussion.contains("monitor.setDiscussionStrictness(.everything)"))

        let missed = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/MissedReplyFeed.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(missed.contains("Button(\"再试一次\") { reload() }"))

        let radar = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Analytics/RelationshipRadarView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(radar.contains("if loaded.isEmpty"))
        XCTAssertTrue(radar.contains("filterEmptyState"))
        XCTAssertTrue(radar.contains("Button(\"打开聊天回顾\")"))
        XCTAssertTrue(radar.contains("Button(\"看全部\")"))
        XCTAssertTrue(radar.contains("正在刷新…"))
        XCTAssertTrue(radar.contains("正在刷新关系雷达"))
        XCTAssertTrue(radar.contains("刷新没有完成，现在还是上次的关系信号。请再试一次。"))
        XCTAssertTrue(radar.contains("companionAnimation(CompanionMotion.ease(), value: refreshError)"))
        XCTAssertFalse(radar.contains("try? RelationshipRadarService.refreshAll"))

        let overview = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Analytics/InsightOverviewDashboard.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(overview.contains("Button(\"关注谁\")"))
        XCTAssertTrue(overview.contains("whitelistAllRead"))
        XCTAssertFalse(overview.contains("getWhitelist()"))
        XCTAssertTrue(overview.contains("Button(\"再试一次\") { onRefresh() }"))
        XCTAssertTrue(overview.contains("SettingsView.Tab.contacts.rawValue"))
        XCTAssertTrue(overview.contains("看今天的聊天回顾"))
        XCTAssertTrue(overview.contains("看近 7 天的聊天回顾"))
        XCTAssertFalse(overview.contains("Button(\"查看\")"))
        let quietNoise = overview.components(separatedBy: "可以先放一放").last ?? ""
        XCTAssertTrue(quietNoise.contains("CompanionRowPressStyle()"))
        XCTAssertFalse(quietNoise.contains("buttonStyle(.plain)"))

        let insightPage = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Analytics/ChatInsightView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(insightPage.contains("resolveChatID"))
        XCTAssertTrue(insightPage.contains("insightStore.reloadError"))
        XCTAssertTrue(insightPage.contains("再试一次读取洞察"))
        XCTAssertTrue(insightPage.contains("companionAnimation(CompanionMotion.ease(), value: insightStore.reloadError)"))
        XCTAssertTrue(overview.contains("item.chatUsername ?? item.source"))

        let coordinator = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Services/Insight/InsightCoordinator.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(coordinator.contains("bindingChatUsernames"))

        let insightStore = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Services/Insight/InsightStore.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(insightStore.contains("ChatMonitor.repairStaleChatNames"))
        XCTAssertFalse(insightStore.contains("try? store.addToWhitelist"))

        let attentionBar = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Analytics/InsightAttentionBar.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(attentionBar.contains("chatUsername ?? source"))

        XCTAssertFalse(CompanionInteractionCopy.missedRepliesFailed.contains("点时间"))
        XCTAssertTrue(CompanionInteractionCopy.missedRepliesFailed.contains("再试一次"))

        let inbox = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/InboxView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(inbox.contains("private var islandEmptyMove"))
        XCTAssertTrue(inbox.contains(".accessibilityElement(children: .contain)"))
        XCTAssertTrue(inbox.contains("islandTaskEmptyMove"))

        XCTAssertTrue(inbox.contains("正在撤销刚才的操作"))
        XCTAssertTrue(inbox.contains("撤销没有成功，请重试。"))
       XCTAssertTrue(inbox.contains("切到全记，查看收起的待办"))
       XCTAssertTrue(inbox.contains("islandOtherScopeWithItems"))
        XCTAssertTrue(inbox.contains("islandConnectionFact"))
        let firstLaunch = inbox.components(separatedBy: "struct IslandFirstLaunchView").last ?? ""
        XCTAssertTrue(firstLaunch.contains("IslandInboxRowButtonStyle("))
        XCTAssertFalse(firstLaunch.contains("CompanionPressStyle()"))
        XCTAssertTrue(inbox.contains("选定当前账号"))
        XCTAssertTrue(inbox.contains("CompanionInteractionCopy.accountSwitchedEmpty"))
        XCTAssertFalse(inbox.contains("数据目录"))
        XCTAssertFalse(inbox.contains("微信可能没开着或没登录。"))

        let approval = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/ApprovalWorkspaceView.swift"),
            encoding: .utf8
        )
        let empty = approval.components(separatedBy: "private var emptyState").last ?? ""
        XCTAssertTrue(empty.contains("AutopilotStartCopy.start"))

       XCTAssertTrue(empty.contains("看待确认的回复"))
       XCTAssertTrue(approval.contains("正在整理…"))
        XCTAssertTrue(approval.contains("case failed = \"没发出去\""))
        XCTAssertFalse(approval.contains("case failed = \"失败\""))
       XCTAssertTrue(approval.contains("这条没有发出。先到微信里看过"))
       XCTAssertTrue(approval.contains("在微信中打开"))
       XCTAssertTrue(approval.contains("要核对请到微信里看这条对话。"))
        XCTAssertFalse(approval.contains("队列项已不存在"))
        XCTAssertTrue(approval.contains("这条已经不在待确认列表里了"))
        XCTAssertTrue(approval.contains(".sent || selected.action == .vipNotified"))
        XCTAssertFalse(approval.contains("autopilotActive ? \"正在整理\" :"))

        XCTAssertTrue(approval.contains("正在暂停…"))
        XCTAssertTrue(approval.contains("startAutopilotAndWait"))
        XCTAssertTrue(approval.contains("remainingSeconds) 秒"))
        XCTAssertFalse(approval.contains("remainingSeconds)s"))
        XCTAssertTrue(discussion.contains("Button(\"检查连接\")"))
        XCTAssertTrue(discussion.contains("Button(\"关注谁\")"))
       XCTAssertTrue(discussion.contains("otherScopeWithItems"))
       XCTAssertTrue(discussion.contains("看未处理的待办"))
        XCTAssertTrue(discussion.contains("去今天看待回和待办"))
        XCTAssertTrue(discussion.contains("关注的对话里还没有待办"))
        XCTAssertFalse(discussion.contains("连上微信并选好对话后"))

       let drafts = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/ReplyDraftsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(drafts.contains("打开今天，从一条消息开始写回复"))

        let dailyRisks = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/DailyReportCommandCenterView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(dailyRisks.contains("monitor.dismissDailyReportRisk(risk)"))
        XCTAssertTrue(dailyRisks.contains(".opacity(isHovered ? 1 : 0.55)"))
        XCTAssertFalse(dailyRisks.contains("if isHovered {"))
        XCTAssertTrue(dailyRisks.contains("lineLimit(isWorkspace ? nil : 2)"))
        XCTAssertTrue(dailyRisks.contains("CompanionInteractionCopy.dailyReportCompleteFailed"))
        XCTAssertFalse(dailyRisks.contains("Button(action: { monitor.markDailyReportActionDone(action) })"))
        XCTAssertTrue(dailyRisks.contains("CompanionInteractionCopy.dailyReportDismissFailed"))
        XCTAssertFalse(dailyRisks.contains("Button(action: { monitor.dismissDailyReportRisk(risk) })"))
        guard let todoJump = dailyRisks.range(of: "到「待办」页看这个对话的事项") else {
            return XCTFail("daily lost the 待办 jump")
        }
        XCTAssertTrue(String(dailyRisks[..<todoJump.lowerBound].suffix(280)).contains("CompanionPressStyle()"))
        XCTAssertFalse(String(dailyRisks[..<todoJump.lowerBound].suffix(160)).contains("buttonStyle(.plain)"))
        XCTAssertTrue(dailyRisks.contains("收起今日高亮"))

        let insight = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Analytics/ChatInsightDetailView.swift"),
            encoding: .utf8
        )
       XCTAssertTrue(insight.contains("还没有时间线。"))
       XCTAssertTrue(insight.contains("showChatDetail(chatUsername: chatUsername, chatName: chatName)"))
       let emptyTimeline = insight.components(separatedBy: "还没有时间线。").last ?? ""
        XCTAssertTrue(emptyTimeline.contains("analyzeActionTitle"))
        XCTAssertTrue(emptyTimeline.contains("analyzeActionHint"))
        XCTAssertTrue(insight.contains("正在分析…"))
        XCTAssertTrue(insight.contains("先重读关注名单，再分析这段聊天"))

        let commitments = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CommitmentTabView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(commitments.contains("Button(\"看全部\")"))
       XCTAssertTrue(commitments.contains("打开今天，从对话里记下承诺"))
        XCTAssertTrue(commitments.contains("关注的对话里还没有记下的承诺"))
        XCTAssertFalse(commitments.contains("更早完成或取消的记录还在本地"))

       let admission = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/AdmissionSettingsView.swift"),
            encoding: .utf8
        )
       XCTAssertTrue(admission.contains("去关注谁添加群"))
        XCTAssertTrue(admission.contains("CompanionRowPressStyle()"))
        XCTAssertTrue(admission.contains("还没有设为不提醒的人。"))
        // A failed read must never masquerade as an empty list: the empty-state
        // copy sits behind an unreadable branch, and the load path takes the
        // Optional read so "did not load" stays distinguishable from "nobody".
        XCTAssertTrue(
            admission.contains("不代表它是空的"),
            "admission lost its 'a failed read is not an empty list' state"
        )
        XCTAssertTrue(
            admission.contains("store.ignoredSendersRead()"),
            "admission must distinguish an unreadable mute list from an empty one"
        )
        XCTAssertTrue(
            admission.contains("store.groupMemberRulesRead()"),
            "admission must distinguish unreadable member rules from empty ones"
        )
        let contactsMuteLists = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/ContactsSettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            contactsMuteLists.contains("store.ignoredSendersRead()"),
            "the block-rules list must not read an unreadable list as empty"
        )
        XCTAssertTrue(admission.contains("添加不提醒的人"))
        XCTAssertTrue(admission.contains("已不提醒"))
        XCTAssertFalse(admission.contains("拉黑"))
       XCTAssertTrue(admission.contains("先在「关注谁」里添加群"))
        XCTAssertTrue(admission.contains("followListUnreadable"))
        XCTAssertTrue(admission.contains("CompanionInteractionCopy.followListUnreadableAdmission"))
        XCTAssertTrue(admission.contains("watchedMemberAdded"))
        XCTAssertTrue(admission.contains("quietGroupSilenced"))
        XCTAssertTrue(admission.contains("mutedPersonAdded"))
        XCTAssertTrue(admission.contains("panelState.showToast"))
        let admissionMode = admission.components(separatedBy: "private var modeSection").last ?? ""
        let admissionModeOnly = admissionMode.components(separatedBy: "private var watchedMemberSection").first ?? admissionMode
        XCTAssertTrue(admissionModeOnly.contains("CompanionRowPressStyle()"))
        XCTAssertFalse(admissionModeOnly.contains("CompanionPressStyle()"))

        XCTAssertTrue(admission.contains("重试保存规则"))
        XCTAssertTrue(admission.contains("正在保存提醒规则"))
        XCTAssertTrue(admission.contains("companionBusyHold(isSaving"))
        XCTAssertTrue(admission.contains("if configSaveFailed"))

        let contacts = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/ContactsSettingsView.swift"),
            encoding: .utf8
        )
      XCTAssertTrue(contacts.contains("看全部联系人"))
        XCTAssertTrue(contacts.contains("还没有关注的人"))
        XCTAssertTrue(contacts.contains("添加之后，助手才知道该看谁。"))
        XCTAssertTrue(contacts.contains("if contacts.isEmpty"))
        XCTAssertTrue(contacts.contains("CompanionRowPressStyle()"))
        XCTAssertTrue(contacts.contains("CompanionInteractionCopy.contactsIndexFailed"))
        XCTAssertFalse(contacts.contains("数据目录"))
        XCTAssertFalse(contacts.contains("联系人索引"))

        XCTAssertFalse(contacts.contains(".alert(\"联系人操作失败\""))
        XCTAssertTrue(contacts.contains("ContactWhitelistTracking"))
        XCTAssertTrue(contacts.contains("whitelistEntryRead"))
        XCTAssertTrue(contacts.contains("CompanionInteractionCopy.followLevelUnreadable"))
        XCTAssertTrue(contacts.contains("CompanionInteractionCopy.followLevelChanged"))
        XCTAssertTrue(contacts.contains("announce: true"))
        XCTAssertTrue(contacts.contains("ContactWhitelistTracking.isGroup"))
        XCTAssertTrue(contacts.contains("暂时读不到"))
        XCTAssertFalse(contacts.contains("getWhitelistEntry"))

        let inspector = contacts.components(separatedBy: "private struct ContactInspectorView").last ?? ""
        XCTAssertTrue(inspector.contains("还没有关注的人"))
        XCTAssertTrue(inspector.contains("CompanionProductCopy.addFollow"))
        XCTAssertTrue(inspector.contains("选择一个人或一个群"))
        XCTAssertTrue(inspector.contains("hasContacts"))
        guard let addRows = contacts.range(of: "ForEach(available.prefix(8)") else {
            return XCTFail("contacts lost the add-follow picker rows")
        }
        let addWindow = String(contacts[addRows.lowerBound...].prefix(1800))
        XCTAssertTrue(addWindow.contains("CompanionRowPressStyle()"))
        XCTAssertFalse(addWindow.contains("CompanionPressStyle()"))

        let onboarding = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/OnboardingView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(onboarding.contains("continueBlocked"))

        let dailyNav = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/DailyReportTabView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(dailyNav.contains("已经是今天"))
        XCTAssertTrue(dailyNav.contains("nextDayHoldReason"))

        let updates = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/AppUpdateSettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(updates.contains("演示界面不会检查或安装更新"))

        let mac = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/MacExperienceSettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(mac.contains("演示界面不会改系统权限"))

        let sync = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/SyncSettingsView.swift"),
            encoding: .utf8
        )
       XCTAssertTrue(sync.contains("演示界面不会选择密钥文件"))
        XCTAssertTrue(sync.contains("聊天读取缓存"))
        XCTAssertTrue(sync.contains("选择密钥文件…"))
        XCTAssertFalse(sync.contains("解密缓存"))
        XCTAssertFalse(sync.contains("解密密钥"))
        XCTAssertFalse(sync.contains("选择 JSON"))
        XCTAssertTrue(sync.contains("检查新消息"))
        XCTAssertFalse(sync.contains("轮询间隔"))
        XCTAssertFalse(sync.contains("WAL/SHM"))
        XCTAssertFalse(sync.contains("wechat-cli"))
        XCTAssertFalse(sync.contains("all_keys.json"))
        XCTAssertFalse(sync.contains("JSON 密钥"))
        XCTAssertTrue(sync.contains("演示界面不会改文件权限"))
        XCTAssertTrue(sync.contains("正在收紧权限…"))
       XCTAssertTrue(sync.contains("tightenKeyPermissions"))
       XCTAssertFalse(sync.contains("chmod 600"))
       XCTAssertTrue(sync.contains("打开完全磁盘访问权限"))
       XCTAssertTrue(sync.contains("Privacy_AllFiles"))
       XCTAssertTrue(sync.contains("演示界面不会改系统权限"))
        XCTAssertTrue(sync.contains("openAccessibilitySettings"))
        XCTAssertTrue(sync.contains("Privacy_Accessibility"))
       XCTAssertTrue(sync.contains("再允许微信操作权限"))
       XCTAssertTrue(sync.contains("CompanionFinder.reveal"))
       XCTAssertTrue(sync.contains("没能打开访达"))
        XCTAssertTrue(sync.contains("exportFailed"))
        XCTAssertTrue(sync.contains("CompanionInteractionCopy.exportToDesktopFailed"))
       XCTAssertTrue(sync.contains("CompanionFinder.openDesktop"))
       XCTAssertFalse(sync.contains("导出失败，请检查桌面写入权限"))
       XCTAssertFalse(sync.contains("当前目录后重试"))
        XCTAssertTrue(sync.contains("密钥文件留在本机"))
        XCTAssertFalse(sync.contains("密钥保留在本机"))
        XCTAssertTrue(sync.contains("private func mutateData(_ operation: () throws -> Int)"))
        XCTAssertTrue(sync.contains("let changes = try operation()"))
        XCTAssertTrue(sync.contains("guard changes > 0"))
        XCTAssertTrue(sync.contains("操作未保存，请重试。原记录仍保留。"))
        XCTAssertFalse(sync.contains("private func mutateData(_ operation: () throws -> Void)"))
        let pendingAsks = (sync.components(separatedBy: "private var pendingAsksList").last ?? "")
            .components(separatedBy: "// MARK: - Helpers").first ?? ""
        XCTAssertFalse(pendingAsks.isEmpty, "pendingAsksList slice is empty")
        XCTAssertTrue(pendingAsks.contains("ask.summary"))
        XCTAssertTrue(pendingAsks.contains("fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(pendingAsks.contains(".lineLimit(1)"),
                       "pending-ask summary is the work object; truncating it hides what the user is completing")
        let recalls = (sync.components(separatedBy: "private var recallsList").last ?? "")
            .components(separatedBy: "private var commitmentsList").first ?? ""
        XCTAssertFalse(recalls.isEmpty, "recallsList slice is empty")
        XCTAssertTrue(recalls.contains("msg.originalText"))
        XCTAssertTrue(recalls.contains("fixedSize(horizontal: false, vertical: true)"))

        let monitorSource = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Services/ChatMonitor.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(monitorSource.contains("try? store.updateDiscussionItemStatus"),
                       "discussion status writes cannot swallow the store result and still publish")
        XCTAssertFalse(monitorSource.contains("try? store.silenceChat"))
        XCTAssertFalse(monitorSource.contains("try? store.snoozeChat"))
        XCTAssertFalse(monitorSource.contains("try? store.clearChatAction"))
        XCTAssertFalse(monitorSource.contains("func silenceChat(_ chatUsername: String)"))
        XCTAssertFalse(monitorSource.contains("func snoozeChat(_ chatUsername: String, until: Int)"))
        XCTAssertFalse(monitorSource.contains("func clearChatAction(_ chatUsername: String)"))
        XCTAssertFalse(monitorSource.contains("try? store.addToWhitelist"))
        XCTAssertFalse(monitorSource.contains("try? store.removeFromWhitelist"))
        XCTAssertFalse(monitorSource.contains("func acceptWhitelistSuggestion"))
        XCTAssertFalse(monitorSource.contains("func addUnreadToWhitelist"))
        XCTAssertFalse(monitorSource.contains("whitelistSuggestions"))
        XCTAssertTrue(monitorSource.contains("discussion status write did not land"))

       let autopilot = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/AutopilotSettingsView.swift"),
            encoding: .utf8
        )
       XCTAssertTrue(autopilot.contains("去关注谁，才能添加排除对象"))
        XCTAssertTrue(autopilot.contains("开始整理后，每次会话会出现在这里。"))
        XCTAssertFalse(autopilot.contains("暂无记录"))

        let picker = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/FirstLaunchContactPicker.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(picker.contains("清除搜索"))

        XCTAssertTrue(picker.contains("正在保存关注范围"))
        XCTAssertTrue(picker.contains("正在保存关注…"))
        XCTAssertTrue(picker.contains("最近的对话没读到。请确认微信已经打开，再试一次。"))
        XCTAssertTrue(picker.contains("再试一次读取最近的对话"))
        XCTAssertTrue(picker.contains("正在读取…"))
        XCTAssertFalse(picker.contains("try? monitor.reader.getSessions()"))

        let firstLaunchAI = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/FirstLaunchAISetupView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(firstLaunchAI.contains("正在保存更改"))
        XCTAssertTrue(firstLaunchAI.contains("重试保存"))
       XCTAssertTrue(firstLaunchAI.contains("测试结果未保存"))
       XCTAssertFalse(firstLaunchAI.contains("try? store.saveAIConnectionEvidence"))
       XCTAssertTrue(firstLaunchAI.contains("没能打开获取访问凭据的页面"))
        XCTAssertTrue(firstLaunchAI.contains("访问凭据"))
        XCTAssertFalse(firstLaunchAI.contains("访问密钥"))
        XCTAssertTrue(firstLaunchAI.contains("testPassed"))
        XCTAssertFalse(firstLaunchAI.contains("testResult.contains(\"成功\")"))

        let dailySource = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/DailyReportCommandCenterView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(dailySource.contains("请先连上微信并完成一次读取，再刷新日报。"))
        XCTAssertFalse(dailySource.contains("成功同步"))
        XCTAssertTrue(dailySource.contains("检查连接"))

        let weekly = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/DailyReportTabView.swift"),
            encoding: .utf8
        )
       XCTAssertTrue(weekly.contains("去选要关注的对话"))
        XCTAssertTrue(weekly.contains("去今天看待办"))
        XCTAssertTrue(weekly.contains("今天的待办出现后会汇总到这里"))
       XCTAssertFalse(weekly.contains("连上微信并关注对话后会出现在这里"))
        XCTAssertTrue(weekly.contains("accessibilityLabel(monitor.dailyReportIsLoading ? \"正在整理…\" : \"刷新今日小结\")"))
       XCTAssertTrue(weekly.contains("没能打开访达"))
       XCTAssertTrue(weekly.contains("CompanionFinder.reveal"))
        XCTAssertTrue(weekly.contains("lineLimit(isWorkspace ? nil : 2)"))
        XCTAssertFalse(weekly.contains("Text(message).lineLimit(1)"))
        XCTAssertTrue(weekly.contains("CompanionInteractionCopy.dailyExportFailed"))
        XCTAssertTrue(weekly.contains("CompanionFinder.openDesktop"))
        XCTAssertFalse(weekly.contains("桌面写入权限"))

      XCTAssertTrue(contacts.contains("看全部可添加的对话"))

        let approvalMute = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/ApprovalWorkspaceView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(approvalMute.contains("offersUnsilence"))
        XCTAssertTrue(approvalMute.contains("已取消静音，可以再确认发送"))
        XCTAssertTrue(approvalMute.contains("companionBusyHold(isSending"))
        XCTAssertTrue(approvalMute.contains("companionBusyHold(busy"))

        let detail = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/ConversationDetailView.swift"),
            encoding: .utf8
        )
       XCTAssertTrue(detail.contains("在微信中查看这段对话"))
        XCTAssertTrue(detail.contains("这段对话暂时没有本地消息。"))
       XCTAssertFalse(detail.contains("暂无消息记录"))
        XCTAssertFalse(detail.contains("发送前记录"))
        XCTAssertTrue(detail.contains("发之前没能核对上一条"))
        XCTAssertTrue(detail.contains("openAccessibilitySettings"))
        XCTAssertTrue(detail.contains("再允许微信操作权限"))

        XCTAssertTrue(contacts.contains("去什么会提醒我添加忽略规则"))
        XCTAssertTrue(contacts.contains("打开今天，从一条消息静音对话"))
        XCTAssertTrue(contacts.contains("正在取消静音…"))
        XCTAssertTrue(contacts.contains("正在恢复…"))
        XCTAssertTrue(contacts.contains("if ok {"))
        XCTAssertTrue(contacts.contains("if !ok {"))

        let missedFeed = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/MissedReplyFeed.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(missedFeed.contains("@Binding var query: String"))
        XCTAssertTrue(missedFeed.contains("没有匹配的消息"))

       XCTAssertTrue(dailySource.contains("检查微信连接后再生成日报"))
        XCTAssertTrue(dailySource.contains("去选要关注的对话后再生成日报"))
       XCTAssertTrue(dailySource.contains("点重新生成即可整理"))
        XCTAssertTrue(dailySource.contains("没有这一天的可用记录"))
        XCTAssertFalse(dailySource.contains("这一天暂无可用记录"))
        XCTAssertTrue(dailySource.contains("copyDraft("))
        XCTAssertTrue(dailySource.contains("CompanionInteractionCopy.copied"))
        XCTAssertTrue(dailySource.contains("CompanionInteractionCopy.copyFailed"))
        XCTAssertFalse(dailySource.contains("WeChatLauncher.copyText(draft)"))

       let onboardingRetry = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/OnboardingView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(onboardingRetry.contains("retrySaveError"))
        XCTAssertTrue(onboardingRetry.contains("重试刚才没完成的一步"))

        let connection = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/WeChatConnectionSetupView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(connection.contains("primaryHoldReason"))
        XCTAssertTrue(connection.contains("正在等微信重新登录"))

        XCTAssertTrue(connection.contains("停止这次准备"))
       XCTAssertTrue(connection.contains("canCancelPreparation"))
       XCTAssertFalse(connection.contains("buttonStyle(.link)"))
        XCTAssertTrue(connection.contains("没能打开微信下载页"))
        XCTAssertFalse(connection.contains("errorMessage = error.localizedDescription"))
        XCTAssertFalse(connection.contains("failed(reason: error.localizedDescription)"))
        XCTAssertTrue(connection.contains("FirstLaunchGuide.userFacingPreparationError(error.localizedDescription)"))

        let hero = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Analytics/InsightHeroSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(hero.contains("正在分析…"))
        XCTAssertTrue(hero.contains("正在汇总今天的聊天"))

        XCTAssertTrue(approvalMute.contains("正在发送…"))
        XCTAssertTrue(approvalMute.contains("先写回复"))
        XCTAssertTrue(approvalMute.contains("正在取消…"))

        XCTAssertTrue(approvalMute.contains("正在保存草稿"))
        XCTAssertTrue(approvalMute.contains("guard !actionBusy else { return }"))

        XCTAssertTrue(approvalMute.contains("if sent { showSendConfirm = false }"))
        XCTAssertTrue(approvalMute.contains("if error == nil { showConfirm = false }"))

        XCTAssertTrue(contacts.contains("正在推断…"))
       XCTAssertTrue(contacts.contains("正在推断关系"))

        let today = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/AssistantTodayView.swift"),
            encoding: .utf8
        )
       XCTAssertTrue(today.contains("正在同步…"))
        XCTAssertTrue(today.contains("正在分析…"))
        XCTAssertTrue(today.contains("正在整理…"))
      XCTAssertTrue(today.contains("todayEmptyAction"))
       XCTAssertTrue(today.contains("查看全部更新"))
       XCTAssertTrue(today.contains("打开待办"))
        XCTAssertTrue(today.contains("CompanionInteractionCopy.accountSwitched"))
        XCTAssertFalse(today.contains("数据目录"))
        let originalLink = today.components(separatedBy: "查看消息原文").last ?? ""
        XCTAssertTrue(String(originalLink.prefix(800)).contains("CompanionPressStyle()"))
        XCTAssertFalse(String(originalLink.prefix(800)).contains("buttonStyle(.plain)"))

        let diagnostics = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/SupportDiagnosticsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(diagnostics.contains("accountSwitchedShort"))
        XCTAssertFalse(diagnostics.contains("数据目录"))

        XCTAssertTrue(today.contains("正在标为已处理"))
        XCTAssertTrue(today.contains("正在保存稍后提醒"))

        XCTAssertTrue(detail.contains("先写回复"))
        XCTAssertTrue(detail.contains("copyReplyToClipboard"))
        XCTAssertTrue(detail.contains("CompanionInteractionCopy.replyCopied"))
        let copyFn = detail.components(separatedBy: "private func copyReplyToClipboard").last ?? ""
        let copyOnly = copyFn.components(separatedBy: "private var replyComposer").first ?? copyFn
        XCTAssertFalse(copyOnly.contains("sendResult ="))
        XCTAssertTrue(copyOnly.contains("copyReceipt ="))
        XCTAssertTrue(detail.contains("copyReceiptFailed ? .orange : CompanionPalette.islandMint"))
        XCTAssertTrue(detail.contains("companionBusyHold(isSending"))
        XCTAssertTrue(detail.contains("if !isSending { showSendConfirm = false }"))
        XCTAssertTrue(detail.contains("正在保存草稿"))
        XCTAssertTrue(detail.contains("if succeeded { showSendConfirm = false }"))
        XCTAssertTrue(approvalMute.contains("if !isSending { showSendConfirm = false }"))
        XCTAssertTrue(approvalMute.contains("if !busy { showConfirm = false }"))
        XCTAssertTrue(detail.contains("Text(isSending ? \"正在发送…\""))
        XCTAssertTrue(approvalMute.contains("Text(isSending ? \"正在发送…\""))
        XCTAssertTrue(approvalMute.contains("Text(busy ? \"正在发送…\""))

        XCTAssertTrue(discussion.contains("if !isBatchClearing { showBatchClearConfirm = false }"))
        XCTAssertTrue(discussion.contains("正在清空待办…"))
        XCTAssertTrue(discussion.contains("先写下待办内容"))
        XCTAssertTrue(discussion.contains("if !isCorrecting { correcting = nil }"))
        XCTAssertTrue(discussion.contains("正在保存更正"))

        XCTAssertTrue(discussion.contains("正在撤销刚才的操作"))
        XCTAssertTrue(discussion.contains("撤销没有成功，请重试。"))
        XCTAssertTrue(commitments.contains("if !isBatchClearing { showBatchClearConfirm = false }"))
        XCTAssertTrue(commitments.contains("正在清空承诺…"))
        XCTAssertTrue(commitments.contains("正在撤销刚才的操作"))
        XCTAssertTrue(drafts.contains("if !isContinuingDraft { pendingContinueDraft = nil }"))
        XCTAssertTrue(drafts.contains("正在替换草稿…"))
        XCTAssertTrue(drafts.contains("if !isDeletingDraft { pendingDeleteDraft = nil }"))
        XCTAssertTrue(drafts.contains("正在删除草稿…"))
        XCTAssertTrue(contacts.contains("if !isAddingContacts { showAddPopover = false }"))
        XCTAssertTrue(contacts.contains("正在添加关注…"))
        XCTAssertTrue(contacts.contains("先选要关注的对话"))
        XCTAssertTrue(drafts.contains("companionBusyHold(isContinuingDraft"))
        XCTAssertTrue(drafts.contains("companionBusyHold(isDeletingDraft"))
        XCTAssertTrue(discussion.contains("companionBusyHold(isBatchClearing"))
        XCTAssertTrue(discussion.contains("companionBusyHold(isSaving"))
        XCTAssertTrue(contacts.contains("companionBusyHold(isDeletingContact"))
        XCTAssertTrue(contacts.contains("companionBusyHold(isAddingContacts"))
        XCTAssertTrue(commitments.contains("companionBusyHold(isBatchClearing"))
        XCTAssertTrue(commitments.contains("companionBusyHold(isCancelling"))
        XCTAssertTrue(connection.contains("companionBusyHold(isChangingAccount"))
        XCTAssertTrue(connection.contains("companionBusyHold(isStartingPreparation"))

        let busyHold = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CompanionStyle.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(busyHold.contains("func companionBusyHold"))
        XCTAssertTrue(autopilot.contains("正在开启自动发送…"))
        XCTAssertTrue(autopilot.contains("if !isEnablingAutoSend"))
        XCTAssertTrue(connection.contains("if !isChangingAccount { showChangeAccountConfirm = false }"))
        XCTAssertTrue(connection.contains("正在更换账号…"))

        let settings = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settings.contains("if !isEnablingPreviewAutoSend { previewAutoSendDialog = false }"))
        XCTAssertTrue(settings.contains("正在开启自动发送…"))
        XCTAssertTrue(settings.contains("companionBusyHold(isEnablingPreviewAutoSend"))

        XCTAssertFalse(settings.contains(".alert(\"操作未保存\""))
        XCTAssertTrue(settings.contains("SettingsInboxErrorBanner"))
        XCTAssertTrue(settings.contains("accessibilityLabel(isSyncing ? \"正在读取新消息\" : \"查看新消息\")"))
        XCTAssertTrue(settings.contains(".id(selectedTab)"))
        XCTAssertTrue(settings.contains(".transition(.opacity)"))
        XCTAssertTrue(settings.contains("companionAnimation(CompanionMotion.pageChange(), value: selectedTab)"))
        guard let wash = settings.range(of: "CompanionBackdrop(tint: selectedTab.accentColor)") else {
            return XCTFail("workspace lost the module wash")
        }
        XCTAssertTrue(
            String(settings[wash.lowerBound...].prefix(280)).contains("companionAnimation(CompanionMotion.pageChange(), value: selectedTab)"),
            "module wash must ease with the page, not snap to the next room colour"
        )
        XCTAssertTrue(commitments.contains("if !isCancelling { pendingCancel = nil }"))
        XCTAssertTrue(commitments.contains("正在取消承诺…"))
        XCTAssertTrue(contacts.contains("if !isDeletingContact { pendingDeleteContact = nil }"))
        XCTAssertTrue(contacts.contains("正在删除联系人…"))
        XCTAssertTrue(contacts.contains("companionBusyHold(isDeletingContact"))
       XCTAssertTrue(contacts.contains("正在保存联系人设置"))
        XCTAssertTrue(contacts.contains("CompanionInteractionCopy.contactSettingsSaved"))
        XCTAssertTrue(contacts.contains("CompanionInteractionCopy.contactRemoved"))
        XCTAssertTrue(contacts.contains("saveError"))
        XCTAssertFalse(contacts.contains("[WCHUD] contacts settings"))
        XCTAssertTrue(autopilot.contains("if !isClearingHistory { showClearConfirm = false }"))
        XCTAssertTrue(autopilot.contains("正在清除记录…"))
        XCTAssertTrue(autopilot.contains("companionBusyHold(isClearingHistory"))
        XCTAssertTrue(autopilot.contains("companionBusyHold(isEnablingAutoSend"))
        XCTAssertTrue(drafts.contains("先写回复内容"))
        XCTAssertTrue(drafts.contains("CompanionInteractionCopy.replyCopied"))
       XCTAssertTrue(drafts.contains("CompanionInteractionCopy.copyFailed"))
        XCTAssertTrue(drafts.contains("feedbackFailed"))
        XCTAssertFalse(drafts.contains("feedback.contains(\"失败\")"))

        let scan = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/WhitelistScanView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(scan.contains("if !isRemovingDismissed { pendingRemoveDismissed = nil }"))
        XCTAssertTrue(scan.contains("正在删除忽略记录…"))
        XCTAssertTrue(scan.contains("companionBusyHold(isRemovingDismissed"))

       XCTAssertTrue(scan.contains("正在添加关注"))
       XCTAssertTrue(scan.contains("正在忽略建议"))
        XCTAssertTrue(scan.contains("还没有扫描建议"))
        XCTAssertTrue(scan.contains("开始扫描值得关注的对话"))
       XCTAssertTrue(scan.contains("去关注谁查看已关注的人"))
       XCTAssertFalse(scan.contains("[WCHUD] AI scan"))
        XCTAssertFalse(scan.contains("数据目录"))
        XCTAssertFalse(scan.contains("个候选"))
        XCTAssertFalse(scan.contains("AI 批次"))
        XCTAssertFalse(scan.contains("候选联系人读取失败"))
        XCTAssertTrue(scan.contains("没能读到近期会话"))
      XCTAssertTrue(scan.contains("请到「AI 服务」看连接"))
       XCTAssertTrue(scan.contains("正在读取会话"))
        XCTAssertFalse(scan.contains("读取消息"))

        let onDemand = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Services/ChatMonitor+OnDemandAnalysis.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(onDemand.contains("localizedDescription"))
       XCTAssertFalse(onDemand.contains("解析失败"))
       XCTAssertFalse(onDemand.contains("暂无可读内容"))

        let autoReply = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Services/AutoReplyGenerator.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(autoReply.contains("暂无"))
        let style = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Services/StyleProfiler.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(style.contains("暂无"))
        XCTAssertTrue(onDemand.contains("CompanionInteractionCopy.displayableAnalysisFailure"))
        XCTAssertTrue(sync.contains("微信账号资料"))
        XCTAssertFalse(sync.contains("微信账号与数据目录"))

       XCTAssertTrue(sync.contains("if !isBindingLegacy { showLegacyBindConfirm = false }"))
        XCTAssertTrue(sync.contains("companionBusyHold(isBindingLegacy"))
        XCTAssertTrue(sync.contains("companionBusyHold(isCancellingCommitment"))
        XCTAssertTrue(sync.contains("companionBusyHold(isInstallingUpdate"))
        XCTAssertTrue(sync.contains("正在绑定旧资料…"))
        XCTAssertTrue(sync.contains("if !isCancellingCommitment { pendingCommitmentCancel = nil }"))

        let rename = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/ChatRenameSheet.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(rename.contains("先写显示名称"))
        XCTAssertTrue(rename.contains("正在保存名称"))
        XCTAssertTrue(rename.contains("companionBusyHold(isSaving"))
        XCTAssertTrue(rename.contains("CompanionInteractionCopy.chatRenamed"))
        XCTAssertTrue(rename.contains("CompanionInteractionCopy.chatNameRestored"))
        XCTAssertTrue(rename.contains("panelState.showToast"))

        let inboxRow = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/InboxRowView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(inboxRow.contains("正在取消关注…"))
        XCTAssertTrue(inboxRow.contains("companionBusyHold(isUntracking"))
        guard let snoozeMenu = inboxRow.range(of: "if showSnoozeMenu {") else {
            return XCTFail("inbox row lost the snooze menu")
        }
        XCTAssertTrue(
            String(inboxRow[snoozeMenu.lowerBound...].prefix(420)).contains(".transition(.islandDetailReveal)"),
            "inbox snooze menu must use islandDetailReveal like the banner and briefing"
        )
        XCTAssertTrue(inboxRow.contains("CompanionInteractionCopy.untrackFailed"))
        XCTAssertTrue(inboxRow.contains("applyFollowChange"))
        XCTAssertTrue(inboxRow.contains("CompanionInteractionCopy.followLevelFailed"))
        XCTAssertTrue(inboxRow.contains("正在标为已处理"))
        XCTAssertTrue(inboxRow.contains("正在保存稍后提醒"))
        XCTAssertTrue(inboxRow.contains("正在保存静音"))
        XCTAssertFalse(inboxRow.contains("confirmationDialog("))
        XCTAssertTrue(inboxRow.contains("IslandInboxRowButtonStyle"))
        XCTAssertFalse(inboxRow.contains(".onTapGesture"))

       XCTAssertTrue(connection.contains("正在开始准备…"))
        XCTAssertTrue(connection.contains("正在准备密钥文件"))
        XCTAssertFalse(connection.contains("正在准备读取密钥"))
        XCTAssertTrue(connection.contains("if !isStartingPreparation { showPreparationConsent = false }"))
        XCTAssertFalse(connection.contains("confirmationDialog("))

        let actionPanel = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/ActionPanelView.swift"),
            encoding: .utf8
        )
       XCTAssertTrue(actionPanel.contains("正在生成回复建议"))
       XCTAssertTrue(actionPanel.contains("正在恢复…"))
        XCTAssertTrue(actionPanel.contains("CompanionInteractionCopy.inboxRestoreFailed"))
        XCTAssertFalse(actionPanel.contains("_ = monitor.restoreInboxItem(item)"))
        XCTAssertTrue(actionPanel.contains("displayableAnalysisFailure"))
        XCTAssertTrue(actionPanel.contains("再试一次整理"))
        XCTAssertTrue(actionPanel.contains("CompanionInteractionCopy.replySuggestionsFailed"))
        XCTAssertFalse(actionPanel.contains("回复建议生成失败"))
        XCTAssertFalse(actionPanel.contains("分析失败，可能是 AI 服务超时"))

        XCTAssertTrue(sync.contains("if !isInstallingUpdate { showInstallConfirm = false }"))
        XCTAssertTrue(sync.contains("正在下载或安装新版本"))
       XCTAssertTrue(updates.contains("正在下载新版本…"))
       XCTAssertTrue(updates.contains("正在安装…"))
       XCTAssertTrue(updates.contains("正在检查…"))
       XCTAssertFalse(updates.contains("return \"检查中…\""))
       XCTAssertFalse(updates.contains(".alert(\"安装新版本？\""))
       XCTAssertTrue(updates.contains("没能打开发布页"))

        let updateService = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Services/AppUpdateService.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(updateService.contains("代码签名"))
        XCTAssertFalse(updateService.contains("校验失败"))
       XCTAssertTrue(updateService.contains("请到发布页手动下载"))

        let imageUnderstanding = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Services/ImageUnderstandingService.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(imageUnderstanding.contains("读不出图上的字"))
        XCTAssertFalse(imageUnderstanding.contains("加密 dat"))
        XCTAssertFalse(imageUnderstanding.contains("OCR失败"))
        XCTAssertFalse(imageUnderstanding.contains("图片识别/OCR"))

       XCTAssertTrue(overview.contains("还没有消息可以分析"))
       XCTAssertTrue(overview.contains("还没有消息可以复制"))
        XCTAssertTrue(overview.contains("没有强行动信号"))
        XCTAssertFalse(overview.contains("暂无强行动信号"))
        XCTAssertTrue(overview.contains("copyOverviewReport"))
        XCTAssertTrue(overview.contains("CompanionInteractionCopy.copied"))
        XCTAssertTrue(overview.contains("CompanionInteractionCopy.copyFailed"))
        XCTAssertFalse(overview.contains("let onCopyReport"))

        let retrospective = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Retrospective/RetrospectiveTabView.swift"),
            encoding: .utf8
        )
       XCTAssertTrue(retrospective.contains("正在生成回顾"))
       XCTAssertTrue(retrospective.contains("正在生成…"))
       XCTAssertFalse(retrospective.contains("生成中"))
       XCTAssertTrue(retrospective.contains("这次回顾没有待办。"))
       XCTAssertTrue(retrospective.contains("这次回顾没有高亮。"))
       XCTAssertFalse(retrospective.contains("暂无待办。"))
        XCTAssertTrue(retrospective.contains("completeTodo"))
        XCTAssertTrue(retrospective.contains("guard changes > 0"))
        XCTAssertTrue(retrospective.contains("commandError"))
        XCTAssertTrue(retrospective.contains("CompanionInteractionCopy.retrospectiveTodoCompleteFailed"))
        XCTAssertFalse(retrospective.contains("monitor.hudStore.updateTodoStatus(todoID: todo.id, status: .completed, completedAt: Date())"))
        XCTAssertTrue(retrospective.contains("displayableRetrospectiveFailure"))
        XCTAssertTrue(retrospective.contains("actionTitle"))
        XCTAssertFalse(retrospective.contains("部分对话分析失败"))
        XCTAssertFalse(retrospective.contains("Could not create"))
        XCTAssertFalse(retrospective.contains("cancelled:"))

        let retroJob = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Services/Retrospective/RetrospectiveJob.swift"),
            encoding: .utf8
        )
       XCTAssertFalse(retroJob.contains("Could not create run row"))
        XCTAssertFalse(retroJob.contains("cancelled:"))
       XCTAssertTrue(retroJob.contains("CompanionInteractionCopy.retrospectiveCancelled"))

       let ai = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/AISettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(ai.contains("正在获取模型列表"))
       XCTAssertTrue(ai.contains("正在测试…"))
       XCTAssertTrue(ai.contains("没能打开获取访问凭据的页面"))
       XCTAssertTrue(ai.contains("获取访问凭据"))
       XCTAssertFalse(ai.contains("获取 API Key"))
       XCTAssertTrue(ai.contains("AISettingsValidation.displayable"))
       XCTAssertFalse(ai.contains("if message.contains(\"模型\")"))
        XCTAssertTrue(ai.contains("AISettingsTestVerdict"))
        XCTAssertTrue(ai.contains("setTestResult"))
        XCTAssertFalse(ai.contains("hasPrefix(\"连接成功\")"))
        XCTAssertFalse(ai.contains("hasPrefix(\"失败\")"))

        let validation = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/AISettingsValidation.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(validation.contains("（HTTP"), "AI settings copy must not paint status codes")
        XCTAssertTrue(validation.contains("static func displayable"))
        XCTAssertFalse(validation.contains("密钥"), "AI credential copy must say 访问凭据, not 密钥")

        let autopilotService = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Services/AutopilotService.swift"),
            encoding: .utf8
        )
       XCTAssertFalse(autopilotService.contains("发送结果无法确认"))
       XCTAssertTrue(autopilotService.contains("attempt.failureMessage ?? CompanionProductCopy.sendUncertain"))
        XCTAssertFalse(autopilotService.contains("仍留在队列里"))
        XCTAssertFalse(autopilotService.contains("已保留在队列"))
        XCTAssertFalse(autopilotService.contains("读不到这条的队列孪生"))
        XCTAssertTrue(dailyRisks.contains("正在生成…"))
        XCTAssertTrue(missed.contains("正在读取没回的消息"))
        XCTAssertTrue(missed.contains("widerMissedWindow"))
        XCTAssertTrue(missed.contains("last3Days"))
        XCTAssertTrue(insight.contains("正在分析…"))

        let source = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/DiscussionSourceView.swift"),
            encoding: .utf8
        )
       XCTAssertTrue(source.contains("再试一次读取原文"))
       XCTAssertTrue(source.contains("正在读取原文…"))
       XCTAssertFalse(source.contains("读取本地聊天记录"))

        let inboxItem = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Data/InboxItem.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(inboxItem.contains("暂时读不到"))
        XCTAssertFalse(inboxItem.contains("同步异常"))

        let sidebar = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Analytics/InsightSidebarView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(sidebar.contains("sidebarFilterEmptyMove"))
        XCTAssertTrue(sidebar.contains("看全部对话"))
        XCTAssertTrue(sidebar.contains("去选要关注的对话"))

        let setup = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CompanionSetupCard.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(setup.contains("正在检测…"))
        XCTAssertTrue(setup.contains("正在重新检测连接"))
        XCTAssertTrue(setup.contains("聊天可读"))
        XCTAssertTrue(setup.contains("AI 能用"))
        XCTAssertFalse(setup.contains("数据库可读"))
        XCTAssertFalse(setup.contains("AI 可达"))

        let guide = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CompanionGuideView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(guide.contains("正在检查…"))
        XCTAssertTrue(guide.contains("正在检查 GitHub 上的新版本"))
        XCTAssertFalse(guide.contains("dailyUseCard.companionStagger"))
        XCTAssertTrue(guide.contains("quickStartCard.companionStagger(index: 0)"))
        XCTAssertTrue(guide.contains("title: \"每天怎么用\", index: 1"))
        XCTAssertTrue(guide.contains("CompanionRowPressStyle()"))
        XCTAssertFalse(guide.contains("CompanionPressStyle()"))
    }

    func testStatusAndReceiptLinesUseCompanionReveal() throws {
        let files = [
            "Views/DiscussionWorkspaceView.swift",
            "Views/CommitmentTabView.swift",
            "Views/DailyReportCommandCenterView.swift",
            "Views/MissedReplyFeed.swift",
            "Views/Analytics/ChatInsightDetailView.swift",
            "Views/Settings/AdmissionSettingsView.swift",
            "Views/Retrospective/RetrospectiveTabView.swift",
            "Views/Settings/AutopilotSettingsView.swift",
            "Views/GroupContextBriefingButton.swift",
            "Views/ApprovalWorkspaceView.swift",
            "Views/Settings/MacExperienceSettingsView.swift",
            "Views/ChatRenameSheet.swift",
            "Views/Settings/SyncSettingsView.swift",
            "Views/Settings/AISettingsView.swift",
            "Views/Settings/NotificationSettingsView.swift",
            "Views/WeChatConnectionSetupView.swift",
            "Views/InboxView.swift",
            "Views/DailyReportTabView.swift",
            "Views/Settings/ContactsSettingsView.swift",
            "Views/AssistantTodayView.swift",
            "Views/ActionPanelView.swift",
            "Views/ReplyDraftsView.swift",
            "Views/Settings/SupportDiagnosticsView.swift",
            "Views/ConversationDetailView.swift",
            "Views/Analytics/RelationshipRadarView.swift",
        ]
        for relative in files {
            let source = try String(
                contentsOf: sourcesRoot().appendingPathComponent(relative),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains(".transition(.companionStatusReveal)"),
                "\(relative) is missing companionStatusReveal"
            )
        }

        let discussion = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/DiscussionWorkspaceView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(discussion.contains("companionAnimation(CompanionMotion.ease(), value: error)"))
        XCTAssertTrue(discussion.contains("companionAnimation(CompanionMotion.ease(), value: receipt)"))
        XCTAssertTrue(discussion.contains("companionAnimation(CompanionMotion.pageChange(), value: showingSource)"))
        XCTAssertTrue(discussion.contains("withMotion(CompanionMotion.pageChange()) { showingSource = true }"))
        guard let sourcePane = discussion.range(of: "if showingSource, let item = selected") else {
            return XCTFail("discussion lost the source pane")
        }
        XCTAssertTrue(
            String(discussion[sourcePane.lowerBound...].prefix(520)).contains(".transition(.companionStatusReveal)"),
            "discussion source/detail swap must transition, not snap"
        )

        let missed = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/MissedReplyFeed.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(missed.contains("companionAnimation(CompanionMotion.ease(), value: monitor.missedReplyError)"))

        let commitments = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CommitmentTabView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(commitments.contains("companionAnimation(CompanionMotion.ease(), value: actionError)"))

        let daily = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/DailyReportTabView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(daily.contains(".transition(.companionStatusReveal)"))

        let toast = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/HUDRootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(toast.contains("accessibilityLabel(\"关闭提示\")"))
        XCTAssertTrue(toast.contains(".frame(width: 22, height: 22)"))
        XCTAssertTrue(toast.contains("guard monitor.restoreInboxItem(item) else {"))
        XCTAssertTrue(toast.contains("panelState.showToast("))
        XCTAssertTrue(toast.contains("CompanionInteractionCopy.inboxRestoreFailed"))
        XCTAssertFalse(toast.contains("guard monitor.restoreInboxItem(item) else { return }"))

        let today = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/AssistantTodayView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(today.contains("Image(systemName: \"ellipsis\")"))
        XCTAssertTrue(today.contains(".transition(.companionStatusReveal)"))
        XCTAssertTrue(today.contains("companionAnimation(CompanionMotion.rowExpand(), value: expanded)"))
        XCTAssertFalse(today.contains("companionStagger"), "today is tens/day; tab switch already has pageChange")
        XCTAssertFalse(today.contains(".disabled(showMissed)"))
        XCTAssertFalse(today.contains(".opacity(showMissed"))
        XCTAssertTrue(today.contains("if !showMissed {"))

        let inbox = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/InboxView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(inbox.contains(".transition(.islandDetailReveal)"))
        XCTAssertTrue(inbox.contains("withMotion(CompanionMotion.islandRowExpand()) { showHandled = true }"))
        XCTAssertTrue(inbox.contains("companionAnimation(CompanionMotion.ease(), value: receipt)"))
        XCTAssertTrue(inbox.contains("正在恢复这条消息"))
        XCTAssertTrue(inbox.contains("restoringHandledID"))
        XCTAssertTrue(inbox.contains("islandInboxActionError"))
        XCTAssertTrue(inbox.contains("monitor.inboxActionError"))
        XCTAssertTrue(inbox.contains("companionAnimation(CompanionMotion.ease(), value: monitor.inboxActionError)"))
        XCTAssertFalse(inbox.contains("handledRestoreError"))
        let buddy = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/PixelBuddyView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(buddy.contains(".transition(.islandDetailReveal)"))
        XCTAssertFalse(buddy.contains(".move(edge: .top)"))
    }

    func testWorkspaceCardsUsePressFeedback() throws {
        let files = [
            "Views/AssistantTodayView.swift",
            "Views/MissedReplyFeed.swift",
            "Views/ApprovalWorkspaceView.swift",
            "Views/Analytics/InsightSidebarView.swift",
            "Views/ReplyDraftsView.swift",
            "Views/CommitmentTabView.swift",
            "Views/Analytics/InsightRadarSection.swift",
            "Views/Analytics/InsightOverviewDashboard.swift",
            "Views/DailyReportCommandCenterView.swift",
            "Views/Settings/ContactsSettingsView.swift",
            "Views/ConversationDetailView.swift",
            "Views/FirstLaunchContactPicker.swift",
            "Views/CompanionSetupCard.swift",
            "Views/Settings/AdmissionSettingsView.swift",
            "Views/Analytics/RelationshipRadarView.swift",
            "Views/DailyReportTabView.swift",
            "Views/Analytics/ChatInsightDetailView.swift",
            "Views/DiscussionSourceView.swift",
            "Views/DiscussionWorkspaceView.swift",
            "Views/Retrospective/RetrospectiveTabView.swift"
        ]
        for relative in files {
            let source = try String(
                contentsOf: sourcesRoot().appendingPathComponent(relative),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains("CompanionPressStyle()"),
                "\(relative) is missing press feedback on tappable cards"
            )
        }

        let detail = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/ConversationDetailView.swift"),
            encoding: .utf8
        )
        let suggestion = detail.components(separatedBy: "private struct SuggestionRowView").last ?? ""
        XCTAssertTrue(suggestion.contains("CompanionPressStyle()"))
        XCTAssertTrue(suggestion.contains("采用这条建议"))
        XCTAssertTrue(suggestion.contains("IslandIconButtonStyle()"))
        XCTAssertFalse(suggestion.contains(".onTapGesture"))
        XCTAssertTrue(detail.contains("IslandIconButtonStyle()"))
        XCTAssertTrue(detail.contains("accessibilityLabel(\"返回收件箱\")"))

        let discussion = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/DiscussionWorkspaceView.swift"),
            encoding: .utf8
        )
        let discussionRow = discussion.components(separatedBy: "private struct DiscussionRow").last ?? ""
        XCTAssertTrue(discussionRow.contains("CompanionRowPressStyle()"))

        let insight = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Analytics/InsightSidebarView.swift"),
            encoding: .utf8
        )
        XCTAssertEqual(insight.components(separatedBy: "CompanionRowPressStyle()").count - 1, 3)

        let radar = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Analytics/RelationshipRadarView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(radar.contains("CompanionRowPressStyle()"))

        let approval = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/ApprovalWorkspaceView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(approval.contains("CompanionRowPressStyle()"))

        let drafts = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/ReplyDraftsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(drafts.contains("CompanionRowPressStyle()"))

        let commitments = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CommitmentTabView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(commitments.contains("CompanionRowPressStyle()"))

        let attention = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Analytics/InsightAttentionBar.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(attention.contains("CompanionRowPressStyle()"))

        let overview = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Analytics/InsightOverviewDashboard.swift"),
            encoding: .utf8
        )
        XCTAssertGreaterThanOrEqual(overview.components(separatedBy: "CompanionRowPressStyle()").count - 1, 2)
        XCTAssertFalse(overview.contains("Button(\"查看\")"))
        let oneWay = overview.components(separatedBy: "单向沟通").last ?? ""
        XCTAssertTrue(oneWay.contains("CompanionRowPressStyle()"))
        XCTAssertFalse(oneWay.contains("buttonStyle(.plain)"))
        XCTAssertTrue(overview.contains("onSelectChat(item.chatUsername)"))
        XCTAssertTrue(overview.contains("onSelectChat(c.chatUsername)"))
        XCTAssertTrue(overview.contains("chatUsername: sym.chatUsername"))
    }

    func testWorkspacePageTitleUsesNativeDisplayToken() throws {
        let source = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("companionFont(size: 30"), "page title must not be 30pt")
        XCTAssertTrue(source.contains("workspaceDisplay()"))
        XCTAssertTrue(source.contains("CompanionPressStyle()"))
        let sidebar = source.components(separatedBy: "private struct SettingsSidebarRow").last ?? ""
        let sidebarOnly = sidebar.components(separatedBy: "private struct SettingsPreviewChrome").first ?? sidebar
        XCTAssertTrue(sidebarOnly.contains("CompanionRowPressStyle()"))
        XCTAssertFalse(sidebarOnly.contains("CompanionPressStyle()"))

        let chrome = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/CompanionStyle.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(chrome.contains("struct CompanionIconButtonStyle"))

        let daily = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/DailyReportTabView.swift"),
            encoding: .utf8
        )
        XCTAssertGreaterThanOrEqual(daily.components(separatedBy: "CompanionIconButtonStyle()").count - 1, 4)

        let overview = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Analytics/InsightOverviewDashboard.swift"),
            encoding: .utf8
        )
        XCTAssertGreaterThanOrEqual(overview.components(separatedBy: "CompanionIconButtonStyle()").count - 1, 2)
        XCTAssertTrue(source.contains("CompanionIconButtonStyle()"))

        let ai = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/AISettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertGreaterThanOrEqual(ai.components(separatedBy: "CompanionIconButtonStyle()").count - 1, 2)

        let sourcePane = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/DiscussionSourceView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(sourcePane.contains("CompanionIconButtonStyle()"))

        XCTAssertTrue(chrome.contains("CompanionIconButtonStyle()"))
    }

    func testSecretStoreErrorsDoNotLeakImplementation() throws {
        XCTAssertEqual(
            SecretStoreError.persistFailed("SecItemAdd -50").errorDescription,
            "访问凭据没能保存，请重试。"
        )
        XCTAssertEqual(
            SecretStoreError.readbackMismatch.errorDescription,
            "访问凭据写完后读回来对不上，已保留原来的。"
        )
        XCTAssertEqual(
            SecretStoreError.unavailable.errorDescription,
            "这台 Mac 现在存不了访问凭据，请重试。"
        )
        for error in [SecretStoreError.persistFailed("SecItemUpdate -34018"), .readbackMismatch, .unavailable] {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.contains("密钥"), text)
            XCTAssertFalse(text.contains("SecItem"), text)
            XCTAssertFalse(text.contains("钥匙串"), text)
        }

        let source = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Data/SecretStore.swift"),
            encoding: .utf8
        )
        let description: String
        if let start = source.range(of: "var errorDescription"),
           let end = source[start.lowerBound...].range(of: "    }\n}") {
            description = String(source[start.lowerBound..<end.upperBound])
        } else {
            return XCTFail("SecretStoreError lost errorDescription")
        }
        XCTAssertFalse(description.contains("\\(message)"))
        XCTAssertTrue(description.contains("访问凭据"))
    }

    func testCustomerFacingLabelsHaveNoForbiddenChrome() {
        let labels = [
            ReplyDebtReasonCode.whitelisted.label,
            WhitelistAttentionLevel.watch.label,
            WhitelistAttentionLevel.watch.shortLabel,
            AttentionLevel.whitelist.label,
            AttentionLevel.greylist.label,
            AttentionLevel.vip.label,
            AttentionLevel.stranger.label
        ]
        for label in labels {
            XCTAssertFalse(label.isEmpty)
            for word in CompanionProductCopy.forbiddenChrome {
                XCTAssertFalse(label.contains(word), "\(label) leaked \(word)")
            }
        }
        XCTAssertEqual(AttentionLevel.whitelist.label, "关注")
        XCTAssertEqual(WhitelistAttentionLevel.watch.label, "关注")
       XCTAssertEqual(ReplyDebtReasonCode.whitelisted.label, "已关注")
        for strategy in CacheStrategy.allCases {
            XCTAssertFalse(strategy.label.contains("解密"), "\(strategy) label leaked 解密")
            XCTAssertFalse(strategy.hint.contains("解密"), "\(strategy) hint leaked 解密")
            XCTAssertFalse(strategy.hint.contains("/tmp"), "\(strategy) hint leaked a path")
            XCTAssertFalse(strategy.hint.contains(".wechat-hud"), "\(strategy) hint leaked a path")
        }
   }

    func testViewsDoNotFireAndForgetAutopilotSession() throws {
        for file in try swiftFiles(under: "Views") {
            XCTAssertFalse(
                file.text.contains("monitor.toggleAutopilot()"),
                "\(file.name) still fire-and-forgets toggleAutopilot"
            )
            XCTAssertFalse(
                file.text.contains("monitor.startAutopilot()"),
                "\(file.name) still fire-and-forgets startAutopilot"
            )
            XCTAssertFalse(
                file.text.contains("monitor.stopAutopilot()"),
                "\(file.name) still fire-and-forgets stopAutopilot"
            )
        }
    }

   func testReadableChromeDoesNotGoBelowTenPoints() throws {
        for file in try swiftFiles(under: "Views") {
            if file.name == "PixelBuddyView.swift" { continue }
            for needle in [".font(.system(size: 6", ".font(.system(size: 7",
                           ".font(.system(size: 8", ".font(.system(size: 9"] {
                XCTAssertFalse(
                    file.text.contains(needle),
                    "\(file.name) still draws readable chrome below 10pt (\(needle))"
                )
            }
        }
    }

    func testTabSubtitlesStayShortAndConcrete() {
        // A page may drop the gloss entirely when the only candidate restated
        // the title (我答应的事 / 已答应的事) — but it may not fill the slot
        // with a sentence, an exclamation, or something the header can't fit.
        for tab in SettingsView.Tab.allCases {
            guard let subtitle = tab.subtitle else { continue }
            XCTAssertFalse(subtitle.isEmpty, tab.rawValue)
            XCTAssertLessThanOrEqual(
                subtitle.count, 12,
                "\(tab.rawValue) subtitle is too long: \(subtitle)"
            )
            XCTAssertFalse(subtitle.contains("！"))
            XCTAssertFalse(subtitle.contains("。"))
        }
        // Two pages carrying the same gloss is how 草稿 and 待确认回复 both
        // promised 确认后发送 while only one of them sends anything.
        let glosses = SettingsView.Tab.allCases.compactMap(\.subtitle)
        XCTAssertEqual(glosses.count, Set(glosses).count, "two pages share a gloss")
    }

    /// Every text run follows Dynamic Type. A hardcoded `.font(.system(size:`
    /// freezes one glyph run at one size forever — §86 task #10 found the
    /// island detail rendering byte-identical at 文字大小=更大, and the app-wide
    /// sweep converted 723 such sites to `companionFont`. One carve-out: the
    /// compact bar's mark glyphs (● dots at 6–8pt) are decoration, not text —
    /// letting them scale would push them out of the 32pt chrome they live in.
    func testNoHardcodedFontSizesOutsideTheMarks() throws {
        for file in try swiftFiles(under: "Views") {
            for line in file.text.split(separator: "\n") {
                guard line.contains(".font(.system(size:") else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                let isMark = file.name == "CompactInboxBar.swift" && line.contains("markSize")
                XCTAssertTrue(
                    isMark,
                    "\(file.name) hardcodes a font size (only the compact bar's mark glyphs may): \(trimmed)"
                )
            }
        }
    }
}
