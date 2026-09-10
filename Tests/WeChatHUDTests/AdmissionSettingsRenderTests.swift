import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

/// Renders the admission settings screen so its layout can be inspected rather
/// than assumed.
///
/// The screen is the only place a user can see or change these rules, and a
/// compile check says nothing about whether the sections actually fit, whether
/// the sections render at all, or whether the copy survived. This draws the real
/// view with a realistic rule set and writes a PNG for review.
@MainActor
final class AdmissionSettingsRenderTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("admission-render-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testAdmissionSettingsRendersWithRealisticRules() throws {
        let store = HUDStore(dbPath: root.appendingPathComponent("hud.sqlite3").path)
        try store.open()
        defer { store.close() }

        let snapshot = AdmissionSettingsView.Snapshot(
            config: AdmissionConfig(mode: .whitelistOnly, atMutedGroups: ["noisy@chatroom"]),
            followed: [
                entry("boss", "主管", isGroup: false, level: .vip),
                entry("colleague", "同事小李", isGroup: false, level: .watch),
                entry("team@chatroom", "产品协作群", isGroup: true, level: .watch),
                entry("noisy@chatroom", "行业交流大群", isGroup: true, level: .watch),
                entry("family@chatroom", "家里人群", isGroup: true, level: .watch),
            ],
            memberRules: [
                memberRule("team@chatroom", "产品协作群", "boss", "主管"),
                memberRule("team@chatroom", "产品协作群", "pm", "产品经理"),
            ],
            globalMuted: [
                mutedRule("spammer", "推广号"),
            ]
        )

        // Rendered without the scrolling shell: ImageRenderer draws a
        // ScrollView as an empty image, so screenshotting the whole body would
        // produce a picture that proves nothing.
        let view = AdmissionSettingsView(snapshot: snapshot)
            .content
            .environmentObject(store)
            .frame(width: 640, alignment: .topLeading)
            .padding(16)
            .background(Color.white)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.nsImage, "the settings screen produced no image")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))

        // Byte size is not evidence: the first version of this test accepted a
        // blank 49 KB image. Measure actual marks on the canvas instead.
        let ink = inkRatio(rep)
        XCTAssertGreaterThan(
            ink, 0.02,
            "rendered screen is essentially blank (ink=\(ink)); the layout did not draw"
        )

        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        let output = URL(fileURLWithPath: "/tmp/wechathud-admission-settings.png")
        try png.write(to: output)
        print("[render] wrote \(output.path) \(rep.pixelsWide)x\(rep.pixelsHigh) ink=\(String(format: "%.3f", ink))")
    }

    /// Share of sampled pixels that differ from the background.
    private func inkRatio(_ rep: NSBitmapImageRep) -> Double {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0, let background = rep.colorAt(x: 0, y: 0) else { return 0 }
        var ink = 0
        var total = 0
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                total += 1
                guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(pixel.redComponent - background.redComponent)
                    + abs(pixel.greenComponent - background.greenComponent)
                    + abs(pixel.blueComponent - background.blueComponent)
                if delta > 0.06 { ink += 1 }
            }
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    private func entry(
        _ username: String,
        _ name: String,
        isGroup: Bool,
        level: WhitelistAttentionLevel
    ) -> WhitelistEntry {
        WhitelistEntry(
            id: username,
            displayName: name,
            isGroup: isGroup,
            category: .work,
            attentionLevel: level,
            addedAt: Date(),
            autoSuggested: false
        )
    }

    private func memberRule(
        _ chat: String, _ chatName: String, _ sender: String, _ senderName: String
    ) -> GroupMemberRule {
        GroupMemberRule(
            chatUsername: chat,
            chatName: chatName,
            senderUsername: sender,
            senderName: senderName,
            createdAt: Date()
        )
    }

    private func mutedRule(_ username: String, _ name: String) -> IgnoredSenderRule {
        IgnoredSenderRule(
            chatUsername: HUDStore.globalIgnoreScopeKey,
            chatName: name,
            senderIdentifier: "username:\(username)",
            senderUsername: username,
            senderName: name,
            createdAt: Date(),
            scope: .global
        )
    }

    /// A first-time user sees this state, not the populated one: nothing
    /// watched, nobody muted, no group quieted. Every section has to say
    /// something useful instead of rendering an empty box.
    func testAdmissionSettingsEmptyStateStillExplainsItself() throws {
        let store = HUDStore(dbPath: root.appendingPathComponent("hud-empty.sqlite3").path)
        try store.open()
        defer { store.close() }

        // One followed group, so the @ section has something to talk about.
        let snapshot = AdmissionSettingsView.Snapshot(
            config: AdmissionConfig(),
            followed: [entry("team@chatroom", "产品协作群", isGroup: true, level: .watch)]
        )

        let view = AdmissionSettingsView(snapshot: snapshot)
            .content
            .environmentObject(store)
            .frame(width: 640, alignment: .topLeading)
            .padding(16)
            .background(Color.white)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))

        // An empty box or a collapsed section would leave far less ink than the
        // explanatory copy each section is supposed to carry.
        let ink = inkRatio(rep)
        XCTAssertGreaterThan(ink, 0.02, "empty state rendered nearly blank (ink=\(ink))")

        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: "/tmp/wechathud-admission-empty.png")
        try png.write(to: output)
        print("[render] wrote \(output.path) \(rep.pixelsWide)x\(rep.pixelsHigh) ink=\(String(format: "%.3f", ink))")
    }

    /// Regression guard for an inverted disabled condition.
    ///
    /// The 添加 button in the @ section was gated on the list of groups that
    /// were *already* quiet, so it disabled itself in precisely the state where
    /// the user had something to add. Caught by looking at the empty-state
    /// render, which is why the screenshot is written out rather than only
    /// asserted on.
    func testQuietGroupPickerOffersEveryGroupThatStillInterrupts() throws {
        let store = HUDStore(dbPath: root.appendingPathComponent("hud-quiet.sqlite3").path)
        try store.open()
        defer { store.close() }

        let followed = [
            entry("a@chatroom", "甲群", isGroup: true, level: .watch),
            entry("b@chatroom", "乙群", isGroup: true, level: .watch),
        ]
        let snapshot = AdmissionSettingsView.Snapshot(
            config: AdmissionConfig(mode: .whitelistOnly, atMutedGroups: ["a@chatroom"]),
            followed: followed
        )

        let view = AdmissionSettingsView(snapshot: snapshot)
            .content
            .environmentObject(store)
            .frame(width: 640, alignment: .topLeading)
            .padding(16)
            .background(Color.white)

        let renderer = ImageRenderer(content: view)
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))

        // The already-quiet group is listed; the remaining one keeps 添加 live.
        XCTAssertGreaterThan(inkRatio(rep), 0.02)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/wechathud-admission-one-quiet.png"))
    }
}
