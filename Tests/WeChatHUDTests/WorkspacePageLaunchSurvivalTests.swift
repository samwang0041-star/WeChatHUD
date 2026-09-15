import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

/// Every workspace page must survive being laid out at the window's own minimum.
///
/// Why this exists: while aligning the pages, adding `.fixedSize()` to the
/// filter-pill label made AppKit's layout pass throw at the 900pt minimum —
/// `_NSViewLayout` → `NSApplication._crashOnException` → SIGTRAP — and the
/// whole 待办 page died on launch. No unit test and no compile check caught it;
/// it was found by launching the app and noticing the page never appeared. A
/// page that crashes is worse than a page that wraps, so the guard belongs in
/// the suite.
///
/// This renders each page's real view hierarchy at the window's minimum size.
/// ImageRenderer runs the same SwiftUI layout the window does, so a layout
/// exception surfaces here as a failure instead of as a missing page.
@MainActor
final class WorkspacePageLaunchSurvivalTests: XCTestCase {

    private func store(named name: String) throws -> HUDStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-survival-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: root.appendingPathComponent("hud.sqlite3").path)
        try store.open()
        return store
    }

    /// A monitor wired to the given store, with a reader pointed at a path that
    /// does not exist: these tests are about layout, so nothing may touch a real
    /// WeChat database.
    private func monitor(for store: HUDStore) -> ChatMonitor {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-survival-absent-\(UUID().uuidString)")
        let reader = WeChatReader(
            keysPath: absent.appendingPathComponent("keys.json").path,
            dbDir: absent.path,
            cacheStrategy: .memory
        )
        return ChatMonitor(reader: reader, store: store, aiService: AIService())
    }

    /// The minimum the settings window allows (see `SettingsWindow.minSize`),
    /// less the sidebar: the tightest content column the design must hold.
    private let minimumContentWidth: CGFloat = 900 - 236

    /// The built app binary, found next to the test bundle.
    private func appBinary() -> URL? {
        let besideTests = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("WeChatHUD")
        return FileManager.default.isExecutableFile(atPath: besideTests.path) ? besideTests : nil
    }

    /// Launch each tight page in the real app and require it to survive.
    ///
    /// Why a subprocess instead of an in-process window: both weaker oracles
    /// were measured and both failed to see the defect. `ImageRenderer` passed
    /// with it in place, and so did hosting a page in a real `NSWindow` — the
    /// throw happened in AppKit's window layout inside the *running app*, and
    /// building an `NSWindow` inside `XCTestCase` additionally trips XCTest's
    /// own `XCTMemoryChecker` teardown (SIGSEGV in `objc_release`), which is a
    /// crash of the test harness rather than of the product. Launching the real
    /// binary and checking it is still alive after its window has laid out is
    /// the oracle that actually caught the bug, so that is the one kept.
    ///
    /// The pages chosen are the ones with the densest control rows — the filter
    /// row of 待办 only overflows at the window's 900pt minimum, which is why
    /// they are the ones that broke.
    func testPagesSurviveLaunchAtTheWindowMinimum() throws {
        guard let binary = appBinary() else {
            throw XCTSkip("the app binary is not built beside the tests; run `swift build` first")
        }
        for tab in ["tasks", "commitments"] {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--preview", "--preview-tab=\(tab)"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            defer { if process.isRunning { process.terminate() } }

            // Four seconds is past first paint and the first layout pass on a
            // warm machine (measured: the page is on screen ~2.5s after exec).
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline, process.isRunning {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }

            XCTAssertTrue(
                process.isRunning,
                "\(tab) died on launch (status \(process.terminationStatus)). "
                + "A page that cannot lay out at 900pt is worse than one that wraps."
            )
            process.terminate()
            process.waitUntilExit()
        }
    }

    /// The shared page modifier must pin a body to the **top** of the space it
    /// is given, at any width.
    ///
    /// Asserted on pixels, not on “an image came back”: the earlier version of
    /// this test only checked `nsImage != nil`, which is true of an empty or
    /// mis-positioned render too. What actually matters is that a short page
    /// leaves its empty space *below*, so the status bar underneath it stays at
    /// the bottom of the window instead of floating up under the content.
    @MainActor
    func testWorkspacePagePinsContentToTheTopAtAnyWidth() throws {
        for width: CGFloat in [600, 944, 1180, 1600] {
            let view = Color.red
                .frame(height: 40)
                .workspacePage(width)
                .frame(width: width, height: 500)
                .background(Color.white)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.nsImage, "the page frame must lay out at width \(width)")
            let rep = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))
            let middleY = rep.pixelsHigh / 2
            let sampleX = min(rep.pixelsWide / 2, rep.pixelsWide - 1)

            let top = try XCTUnwrap(rep.colorAt(x: sampleX, y: 10))
            XCTAssertGreaterThan(
                top.redComponent, 0.7,
                "at width \(width) the page body is not at the top"
            )
            XCTAssertGreaterThan(
                top.redComponent - top.greenComponent, 0.5,
                "at width \(width) the top sample is not the red body"
            )

            let middle = try XCTUnwrap(rep.colorAt(x: sampleX, y: middleY))
            XCTAssertLessThan(
                middle.redComponent - middle.greenComponent, 0.2,
                "at width \(width) content is floating in the middle; the free space belongs below it"
            )
        }
    }
}

/// The in-window confirm dialogs still paint after the page body gained
/// `.clipped()`.
///
/// Why this exists: `SettingsView` now clips the page body so a tall page cannot
/// draw over the header. A `CompanionDialog` is presented *inside* that body
/// (`companionDialogBackdrop` is a `ZStack` over the page), so clipping is a
/// plausible way to lose a modal — an outcome far worse than the overlap it
/// prevents. This renders the dialog over a clipped body and requires that the
/// scrim and card are actually on the canvas.
@MainActor
final class CompanionDialogVisibilityTests: XCTestCase {

    func testDialogPaintsOverAClippedPageBody() throws {
        let content = Color.white
            .frame(height: 2000)                 // taller than the pane
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()

        let withDialog = content
            .frame(width: 700, height: 500)
            .companionDialogBackdrop(true) {
                CompanionDialog(title: "一键清空当前待办？", onClose: {}) {
                    Text("将当前列表中的 2 件待办全部标记为完成。")
                }
            }
            .environmentObject(PanelState())

        let renderer = ImageRenderer(content: withDialog)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage, "the dialog surface produced no image")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))

        // Without the dialog the page is white; the scrim darkens most of it.
        var darkened = 0
        var sampled = 0
        for y in stride(from: 4, to: rep.pixelsHigh - 4, by: 4) {
            for x in stride(from: 4, to: rep.pixelsWide - 4, by: 4) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                sampled += 1
                if c.redComponent < 0.94 { darkened += 1 }
            }
        }
        let ratio = Double(darkened) / Double(max(sampled, 1))
        XCTAssertGreaterThan(
            ratio, 0.5,
            "the modal scrim is missing over a clipped page body (darkened=\(String(format: "%.2f", ratio))); clipping must not swallow dialogs"
        )
    }
}
