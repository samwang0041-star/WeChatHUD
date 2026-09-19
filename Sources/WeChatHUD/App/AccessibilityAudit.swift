import AppKit
import ApplicationServices
import Foundation

/// Measures the running app against the two macOS HIG rules a screenshot
/// cannot show:
///
/// 1. **Click targets.** A control the pointer cannot comfortably hit is a
///    defect that looks fine in a still image. Apple's macOS control metrics
///    put the comfortable floor at 24×24 pt; several of this app's icon
///    buttons are drawn at 10–13 pt glyph size, so whether they clear that
///    floor is a measurement, not an opinion.
/// 2. **Spoken names and tooltips.** A button whose only content is an SF
///    Symbol has no text for VoiceOver to read and nothing for a hover to
///    explain. Neither shows up in a screenshot either.
///
/// The numbers come from this process's own `AXUIElement` tree — the same tree
/// VoiceOver and the QA scripts read — not from parsing the source. Source
/// scanning is a useful second gate, but it can only see what was written;
/// this sees what was built, including sizes that only exist after layout.
///
/// Measured through AX rather than `NSAccessibilityProtocol` on purpose:
/// SwiftUI renders a whole window into one `NSHostingView`, so asking the view
/// hierarchy for `accessibilityChildren()` returns one element and reports a
/// clean bill of health for a window full of controls. The first run of this
/// audit did exactly that and printed `controls=1`.
///
/// Enabled by `--preview-hig-audit=<seconds>`; writes
/// `$TMPDIR/wechathud-hig-audit.json` and prints a one-line summary.
@MainActor
enum AccessibilityAudit {

    struct Control: Codable {
        var window: String
        var role: String
        var label: String
        var help: String
        var width: Double
        var height: Double
        /// Screen coordinates of the control's top-left, so a report can point
        /// at the same control in a screenshot instead of describing it.
        var x: Double
        var y: Double
        var enabled: Bool
    }

    struct Report: Codable {
        var controls: [Control]
        var windowCount: Int
        /// The AX element that currently holds keyboard focus, as
        /// `role:label`. This is how a keyboard-shortcut claim can be checked
        /// end to end: post the chord, then read where focus actually landed.
        var focusedElement: String
        /// Menu-bar items, top level. A menu-bar app with no `NSApp.mainMenu`
        /// renders the app name and nothing else; the count is the cheapest
        /// evidence that the menu the tests assert is the one on screen.
        var mainMenuTitles: [String]
    }

    /// Roles a pointer has to be able to hit. Static text and groups are
    /// excluded: they are not targets, so their bounds say nothing.
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXMenuItem", "AXLink", "AXSlider",
        "AXDisclosureTriangle", "AXComboBox", "AXTextField"
    ]

    /// Apple's macOS control metrics: the regular push button is 22 pt tall and
    /// the small one 19. 24 pt is the comfortable target below which a control
    /// starts costing the pointer accuracy the platform does not ask for.
    static let minimumTarget: Double = 24

    static func run(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            write(measure())
        }
    }

    static func measure() -> Report {
        let app = AXUIElementCreateApplication(getpid())
        var controls: [Control] = []
        var windowCount = 0
        for window in elements(app, kAXWindowsAttribute) {
            windowCount += 1
            let name = windowName(for: window)
            walk(window, window: name, depth: 0, into: &controls)
        }
        return Report(
            controls: controls,
            windowCount: windowCount,
            focusedElement: focusedElementDescription(),
            mainMenuTitles: (NSApp.mainMenu?.items ?? []).map(\.title)
        )
    }

    /// A name a human can act on, matched to the real `NSWindow`.
    ///
    /// Both the floating island and the onboarding window have an empty AX
    /// title, so title alone reported every one of them as `window` — and the
    /// report then could not say *which* window a 12pt target was in, which is
    /// the only part of the finding that is actionable. Matching the AX
    /// window's frame against the AppKit windows fixes the attribution; the
    /// geometry comes from the same two sources, so a mismatch means the AX
    /// window is not one of ours (a status-item popover, for instance) and
    /// saying so is better than guessing.
    private static func windowName(for window: AXUIElement) -> String {
        let origin = point(window, kAXPositionAttribute)
        let size = size(window, kAXSizeAttribute)
        let axFrame = CGRect(origin: origin, size: size)
        let match = NSApp.windows
            .filter { $0.isVisible && $0.contentView != nil }
            .min { distance($0.frame, axFrame) < distance($1.frame, axFrame) }
        guard let match, distance(match.frame, axFrame) < 4 else {
            // Not one of our windows: the status item's menu, or an island
            // frame caught mid-spring. Saying so beats guessing a name.
            let title = string(window, kAXTitleAttribute) ?? ""
            return title.isEmpty ? "ax-only" : title
        }
        if match is FloatingPanel { return "island" }
        if let identifier = match.identifier?.rawValue, !identifier.isEmpty { return identifier }
        return match.title.isEmpty ? "window" : match.title
    }

    private static func distance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    /// The system-wide focused element, read from the AX server rather than
    /// from AppKit: SwiftUI does not report first responder through
    /// `NSWindow.firstResponder` for its own controls.
    private static func focusedElementDescription() -> String {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let element = focused else { return "" }
        let ax = element as! AXUIElement
        let role = string(ax, kAXRoleAttribute) ?? "?"
        let label = string(ax, kAXDescriptionAttribute)
            ?? string(ax, kAXTitleAttribute)
            ?? string(ax, kAXValueAttribute)
            ?? ""
        return "\(role):\(label.prefix(40))"
    }

    private static func walk(
        _ element: AXUIElement,
        window: String,
        depth: Int,
        insideScrollBar: Bool = false,
        into controls: inout [Control]
    ) {
        // SwiftUI nests deeply; a runaway recursion would hang the app under
        // audit instead of reporting on it.
        guard depth < 40 else { return }
        let role = string(element, kAXRoleAttribute) ?? ""
        let inScrollBar = insideScrollBar || role == "AXScrollBar"
        // The window's own traffic lights are Apple's controls at Apple's
        // size, and a scroll bar's arrow halves are a 11×107 sliver that no
        // pointer aims at directly. Reporting either would drown the findings
        // that are ours to fix.
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        let isSystemChrome = ["AXCloseButton", "AXMinimizeButton",
                              "AXZoomButton", "AXFullScreenButton"].contains(subrole)
        if interactiveRoles.contains(role), !inScrollBar, !isSystemChrome {
            let size = size(element, kAXSizeAttribute)
            let origin = point(element, kAXPositionAttribute)
            // A degenerate frame is not a target: it cannot be hit, so its
            // label and size say nothing about the interface.
            if size.width >= 1, size.height >= 1 {
                controls.append(
                    Control(
                        window: window,
                        role: role,
                        label: string(element, kAXDescriptionAttribute)
                            ?? string(element, kAXTitleAttribute)
                            ?? "",
                        help: string(element, kAXHelpAttribute) ?? "",
                        width: Double(size.width),
                        height: Double(size.height),
                        x: Double(origin.x),
                        y: Double(origin.y),
                        enabled: bool(element, kAXEnabledAttribute) ?? true
                    )
                )
            }
        }
        for child in elements(element, kAXChildrenAttribute) {
            walk(child, window: window, depth: depth + 1, insideScrollBar: inScrollBar, into: &controls)
        }
    }

    // MARK: - AX helpers

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else {
            return nil
        }
        return out
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        value(element, attribute) as? Bool
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(element, attribute) as? [AXUIElement] ?? []
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
            return .zero
        }
        var size = CGSize.zero
        AXValueGetValue(raw as! AXValue, .cgSize, &size)
        return size
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
            return .zero
        }
        var point = CGPoint.zero
        AXValueGetValue(raw as! AXValue, .cgPoint, &point)
        return point
    }

    static func write(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wechathud-hig-audit.json")
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: url)
        // `label`/`help` are read off live controls, so this file can carry
        // contact names and message-derived text. $TMPDIR is per-user but the
        // mode is not: 0644 makes a QA artifact world-readable.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)

        let live = report.controls.filter(\.enabled)
        // Two different rules, deliberately not merged.
        //
        // A **text** control is as big as its text: a macOS link is ~15pt tall
        // and a small bordered button 19, both by Apple's own metrics. Scoring
        // those against 24 would flag the platform, not this app.
        //
        // An **icon-only** control has no text to size it, so its frame *is*
        // the target — that is where the 24pt floor belongs, and it is also the
        // case a screenshot hides and VoiceOver cannot announce.
        let iconOnly = live.filter { $0.label.isEmpty }
        let smallIcons = iconOnly.filter { $0.height < minimumTarget || $0.width < minimumTarget }
        let undersizedText = live.filter {
            !$0.label.isEmpty && ($0.height < 18 || $0.width < 18)
        }
        print("[HIG-AUDIT] focus=\(report.focusedElement)")
        print("[HIG-AUDIT] mainMenu=\(report.mainMenuTitles.joined(separator: "|"))")
        print("[HIG-AUDIT] windows=\(report.windowCount) controls=\(live.count) "
              + "iconOnly=\(iconOnly.count) smallIcons=\(smallIcons.count) "
              + "undersizedText=\(undersizedText.count) -> \(url.path)")
        for control in smallIcons.prefix(20) {
            print("[HIG-AUDIT]   small-icon \(control.window) \(control.role) "
                  + "\(Int(control.width))x\(Int(control.height)) "
                  + "at \(Int(control.x)),\(Int(control.y)) help=“\(control.help)”")
        }
        for control in undersizedText.prefix(20) {
            print("[HIG-AUDIT]   tiny-text \(control.window) \(control.role) "
                  + "\(Int(control.width))x\(Int(control.height)) "
                  + "at \(Int(control.x)),\(Int(control.y)) “\(control.label)”")
        }
    }
}
