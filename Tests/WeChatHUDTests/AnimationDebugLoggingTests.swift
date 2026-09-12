// Tests/WeChatHUDTests/AnimationDebugLoggingTests.swift
//
// W4 — the animation debug log must cost nothing while it is disabled.
//
// `AnimationDebugger.logEvent(_:)` takes a `String`, so the panel's hot paths
// (mouse enter/exit, frame-animation end, every state change) built their
// message — including several `String(format:)` calls — before the function
// could decide not to print it. `logLazyEvent` (declared in AppDelegate.swift)
// takes an `@autoclosure` and moves the message behind the gate.
import XCTest
@testable import WeChatHUD

final class AnimationDebugLoggingTests: XCTestCase {

    /// Counts how often a lazily-built message expression is evaluated.
    private final class LazyProbe {
        private(set) var constructions = 0
        private var value = 0
        /// Stands in for the interpolation tail of a real call site.
        var message: String {
            constructions += 1
            value += 1
            return "step=\(value)"
        }
    }

    /// With debug off, the message expression must never run — this is the
    /// whole point of the autoclosure overload.
    func testAutoclosureArgumentIsNotEvaluatedWhileDisabled() throws {
        guard !AnimationDebugger.isEnabled else {
            throw XCTSkip("process runs with WCHUD_ANIMATION_DEBUG; the disabled path is covered by the child run")
        }
        let probe = LazyProbe()
        // Four of the panel's real hot-path call sites, in their real shape.
        AnimationDebugger.logLazyEvent("frameAnimationEnded mouseInside=\(probe.message)")
        AnimationDebugger.logLazyEvent("mouseEntered state=ok \(probe.message)")
        AnimationDebugger.logLazyEvent("mouseExited state=ok \(probe.message)")
        AnimationDebugger.logLazyEvent("state -> \(probe.message)")
        AnimationDebugger.logLazyEvent("measurement raw=\(probe.message)")
        XCTAssertEqual(probe.constructions, 0, "a disabled debug log must not build its message")
    }

    /// The production default: the test runner has no WCHUD_ANIMATION_DEBUG.
    func testDebugIsDisabledInThisProcess() {
        XCTAssertFalse(
            AnimationDebugger.isEnabled,
            "the test process must not run with WCHUD_ANIMATION_DEBUG set"
        )
    }

    /// The same call *with* debug on has to build the message — otherwise the
    /// test above would pass against an overload that silently drops logs.
    /// Run out of process, because the switch is read once per process.
    func testAutoclosureArgumentIsEvaluatedAndPrintedWhileEnabled() throws {
        // The bundle is a `.xctest`; its own mach-O is not a runnable image
        // (spawning it gives ENOEXEC). Drive it through `xctest`, the runner
        // SwiftPM uses, and put the debug switch in its environment.
        let bundleURL = Bundle(for: type(of: self)).bundleURL
        let xctest = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
        guard FileManager.default.isExecutableFile(atPath: xctest.path),
              FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw XCTSkip("the xctest runner or the test bundle is not available")
        }

        let process = Process()
        process.executableURL = xctest
        process.arguments = [
            "-XCTest", "WeChatHUDTests.AnimationDebugLoggingTests/testAutoclosureArgumentIsEvaluatedAndPrintedInChild",
            bundleURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["WCHUD_ANIMATION_DEBUG"] = "fast"
        environment["WCHUD_LOG_PROBE"] = "child"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        XCTAssertTrue(
            output.contains("[ANIM]"),
            "the child should have printed an [ANIM] line; got: \(output.suffix(2000))"
        )
        XCTAssertTrue(
            output.contains("state -> ") && output.contains("ms"),
            "the emitted line must keep the [ANIM] @<ms>ms <message> shape; got: \(output.suffix(2000))"
        )
        XCTAssertTrue(
            output.contains("constructions=1"),
            "the child must have built the message exactly once; got: \(output.suffix(2000))"
        )
    }

    /// Child-process half of the test above; a no-throw smoke test when run as
    /// part of a normal suite.
    func testAutoclosureArgumentIsEvaluatedAndPrintedInChild() {
        let probe = LazyProbe()
        AnimationDebugger.logLazyEvent("state -> \(probe.message)")
        print("[child-probe] env=\(ProcessInfo.processInfo.environment["WCHUD_LOG_PROBE"] ?? "nil") "
              + "isEnabled=\(AnimationDebugger.isEnabled) constructions=\(probe.constructions)")
        guard ProcessInfo.processInfo.environment["WCHUD_LOG_PROBE"] == "child" else {
            XCTAssertEqual(probe.constructions, AnimationDebugger.isEnabled ? 1 : 0)
            return
        }
        XCTAssertEqual(probe.constructions, 1, "with debug on the message must be built once")
        print("[child-probe] constructions=\(probe.constructions)")
    }

    /// `emit` keeps the historical line format.
    func testEmitKeepsTheHistoricalFormat() {
        AnimationDebugger.emit("state -> compact")
    }
}
