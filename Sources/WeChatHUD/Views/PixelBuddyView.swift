// Sources/WeChatHUD/Views/PixelBuddyView.swift
import SwiftUI

// MARK: - AI Buddy Overlay (hover shows AI activity)

struct AIBuddyOverlay: View {
    let mood: BuddyMood
    @EnvironmentObject var monitor: ChatMonitor
    @ObservedObject private var tracker = AIActivityTracker.shared
    @State private var isHovering = false
    @State private var now = Date()
    @State private var refreshTimer: Timer?

    /// Mood priority: active AI work beats autopilot (transient signal
    /// wins over persistent session), autopilot beats the passed-in mood
    /// (persistent session beats idle/pending). Empty autopilot state
    /// leaves the caller's mood alone.
    private var effectiveMood: BuddyMood {
        if tracker.isActive { return .analyzing }
        if monitor.autopilotActive { return .autopiloting }
        return mood
    }

    var body: some View {
        // Details panel ONLY on hover — never auto-expand just because
        // AI is running. Auto-expansion during background work broke
        // the island metaphor by covering half the inbox with a
        // rectangular white card. The buddy's mood (analyzing vs
        // idle) is the always-on signal; full task breakdown waits
        // for the user to actually ask for it.
        ZStack(alignment: .topTrailing) {
            PixelBuddyView(mood: effectiveMood)
                .onHover { hovering in
                    withMotion(CompanionMotion.ease(0.15)) { isHovering = hovering }
                    if hovering { startRefresh() } else { stopRefresh() }
                }

            if isHovering {
                activityPanel(now: now)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .offset(y: 22)
                    .zIndex(1)
            }
        }
        .onDisappear { stopRefresh() }
    }

    private func startRefresh() {
        stopRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async { now = Date() }
        }
    }

    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func activityPanel(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 5) {
                Circle()
                    .fill(tracker.isActive ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 5, height: 5)
                Text(tracker.isActive ? "AI \(tracker.taskList.count) 个任务" : "AI 空闲")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(tracker.isActive ? .primary : .secondary)
            }

            // Active tasks
            ForEach(tracker.taskList) { task in
                activeRow(task, now: now)
            }

            // Recent completed (dimmed)
            if !tracker.recentCompleted.isEmpty && isHovering {
                Divider().opacity(0.3)
                ForEach(tracker.recentCompleted.prefix(5)) { task in
                    completedRow(task, now: now)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
        )
        .fixedSize()  // allow natural width, can exceed panel bounds
    }

    private func activeRow(_ task: AIActivityTracker.TaskInfo, now: Date) -> some View {
        HStack(spacing: 5) {
            ProgressView()
                .scaleEffect(0.4)
                .frame(width: 8, height: 8)
            Text(task.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.primary)
            if !task.detail.isEmpty {
                Text(task.detail)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text(elapsedText(task.elapsed(now: now)))
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.orange)
        }
    }

    private func completedRow(_ task: AIActivityTracker.TaskInfo, now: Date) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 6, weight: .bold))
                .foregroundColor(.green.opacity(0.6))
                .frame(width: 8, height: 8)
            Text(task.label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            if !task.detail.isEmpty {
                Text(task.detail)
                    .font(.system(size: 7))
                    .foregroundColor(.secondary.opacity(0.6))
                    .lineLimit(1)
            }
            if let ended = task.endedAt {
                Text(String(format: "%.1fs", ended.timeIntervalSince(task.startedAt)))
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
    }

    private func elapsedText(_ interval: TimeInterval) -> String {
        let s = Int(interval)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m\(s % 60)s"
    }
}

// MARK: - Pixel Color Palette

enum PixelColor: UInt32 {
    case clear  = 0x00000000
    case skin   = 0xFFD4A574
    case hair   = 0xFF8B6F5E
    case shirt  = 0xFF5BA0E8
    case pants  = 0xFF6B7B8D
    case eye    = 0xFFE8E8E8
    case accent = 0xFFFF6B6B

    var swiftUIColor: Color {
        if self == .clear { return .clear }
        let r = Double((rawValue >> 16) & 0xFF) / 255.0
        let g = Double((rawValue >> 8) & 0xFF) / 255.0
        let b = Double(rawValue & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Buddy Mood

enum BuddyMood: CaseIterable, Equatable {
    case idle
    case scanning
    case pending
    case urgent
    case error
    case sleepy
    case browsing
    case analyzing
    case celebrating
    /// Autopilot session is active. Renders idle-like sprite with an
    /// antenna/cap overlay so the user can glance at the buddy and know
    /// the AI is actively handling replies.
    case autopiloting
}

// MARK: - Mood Derivation (pure function for testability)

/// Derive compact-bar mood from sync status and inbox items.
/// Same priority as `CompactIslandPolicy`: connection > P0 > work > pending > idle.
func deriveCompactMood(syncStatus: SyncStatus, hasUrgent: Bool, hasPending: Bool, idleMinutes: Int) -> BuddyMood {
    var actions: [CompactIslandAction] = []
    if hasUrgent {
        actions.append(CompactIslandAction(priority: .p0, isVIP: false, isOverdue: false))
    } else if hasPending {
        actions.append(CompactIslandAction(priority: .p2, isVIP: false, isOverdue: false))
    }
    return CompactIslandPolicy.snapshot(CompactIslandInput(
        sync: syncStatus,
        actions: actions,
        noticeCount: 0,
        aiActive: false,
        autopilotActive: false,
        idleMinutes: idleMinutes,
        worstVIPTier: .none
    )).buddy
}

/// Derive extended-inbox mood from inbox state and AI activity.
func deriveExtendedMood(actionItemCount: Int, isAIProcessing: Bool) -> BuddyMood {
    if actionItemCount == 0 { return .celebrating }
    if isAIProcessing { return .analyzing }
    return .browsing
}

// MARK: - Frame Data

/// Short aliases for readability in frame literals
private let O = PixelColor.clear
private let S = PixelColor.skin
private let H = PixelColor.hair
private let T = PixelColor.shirt
private let P = PixelColor.pants
private let E = PixelColor.eye
private let A = PixelColor.accent

/// A single frame: 24 rows × 24 columns
typealias Frame = [[PixelColor]]

// MARK: - Idle frames (standing, breathing, blink)

/// Base standing pose — arms at sides, neutral face
private let idleStand: Frame = {
    var f = Array(repeating: Array(repeating: O, count: 24), count: 24)
    // Hair (rows 6-8, cols 10-14)
    for c in 10...14 { f[6][c] = H; f[7][c] = H }
    for c in 10...14 { f[8][c] = H }
    // Face (rows 9-12, cols 10-14)
    for r in 9...12 { for c in 10...14 { f[r][c] = S } }
    // Eyes (row 10, cols 11 and 13)
    f[10][11] = E; f[10][13] = E
    // Neck (row 13, cols 11-13)
    for c in 11...13 { f[13][c] = S }
    // Shirt (rows 14-17, cols 9-15)
    for r in 14...17 { for c in 9...15 { f[r][c] = T } }
    // Arms (rows 14-17, cols 8 and 16)
    for r in 14...17 { f[r][8] = S; f[r][16] = S }
    // Pants (rows 18-20, cols 10-14)
    for r in 18...20 { for c in 10...14 { f[r][c] = P } }
    // Legs/feet (rows 21-22, cols 10-11 and 13-14)
    for r in 21...22 { f[r][10] = P; f[r][11] = P; f[r][13] = P; f[r][14] = P }
    return f
}()

/// Blink frame — eyes closed (horizontal line instead of dot)
private let idleBlink: Frame = {
    var f = idleStand
    f[10][11] = S; f[10][13] = S  // eyes become skin-colored
    return f
}()

/// Breathe frame — shirt one pixel taller (slight expand)
private let idleBreathe: Frame = {
    var f = idleStand
    f[16][8] = T; f[16][16] = T
    return f
}()

/// Look right — eyes shift right
private let idleLookRight: Frame = {
    var f = idleStand
    f[10][11] = S; f[10][13] = S  // clear original eyes
    f[10][12] = E; f[10][14] = E  // shift right
    return f
}()

// MARK: - Scanning frames (holding magnifying glass)

private let scanFrame1: Frame = {
    var f = idleStand
    for r in 14...17 { f[r][16] = O }  // remove resting arm
    f[12][16] = S; f[13][16] = S; f[13][17] = S  // arm up
    f[11][17] = A; f[11][18] = A; f[12][18] = A; f[12][17] = A
    return f
}()

private let scanFrame2: Frame = {
    var f = scanFrame1
    f[12][17] = O; f[12][18] = O
    f[10][17] = A; f[10][18] = A
    return f
}()

// MARK: - Pending frames (waving a flag)

private let pendingFrame1: Frame = {
    var f = idleStand
    for r in 14...17 { f[r][16] = O }
    f[11][16] = S; f[12][16] = S; f[13][16] = S
    f[9][17] = A; f[9][18] = A; f[10][17] = A; f[10][18] = A
    return f
}()

private let pendingFrame2: Frame = {
    var f = pendingFrame1
    f[9][18] = O; f[10][18] = O
    f[9][19] = A; f[10][19] = A
    return f
}()

// MARK: - Urgent frames (jumping + exclamation mark)

private let urgentFrame1: Frame = {
    var f = Array(repeating: Array(repeating: O, count: 24), count: 24)
    for r in 0..<22 {
        for c in 0..<24 {
            if r + 2 < 24 { f[r][c] = idleStand[r + 2][c] }
        }
    }
    f[2][12] = A; f[3][12] = A; f[5][12] = A
    return f
}()

private let urgentFrame2: Frame = {
    var f = idleStand
    f[3][12] = A; f[4][12] = A
    return f
}()

// MARK: - Error frames (crouching + question mark)

private let errorFrame1: Frame = {
    var f = Array(repeating: Array(repeating: O, count: 24), count: 24)
    for r in 2..<24 {
        for c in 0..<24 { f[r][c] = idleStand[r - 2][c] }
    }
    for r in 22...23 { for c in 0..<24 { f[r][c] = O } }
    f[6][12] = A; f[6][13] = A; f[7][13] = A; f[8][12] = A; f[10][12] = A
    return f
}()

private let errorFrame2: Frame = {
    var f = errorFrame1
    f[10][12] = O
    return f
}()

// MARK: - Sleepy frames (sitting, Z's)

private let sleepyFrame1: Frame = {
    var f = Array(repeating: Array(repeating: O, count: 24), count: 24)
    for c in 10...14 { f[10][c] = H; f[11][c] = H }
    for r in 12...15 { for c in 10...14 { f[r][c] = S } }
    f[13][11] = E; f[13][13] = S
    for r in 16...19 { for c in 9...15 { f[r][c] = T } }
    for c in 10...17 { f[20][c] = P; f[21][c] = P }
    f[7][15] = A; f[7][16] = A; f[8][16] = A; f[9][15] = A; f[9][16] = A
    return f
}()

private let sleepyFrame2: Frame = {
    var f = sleepyFrame1
    f[7][15] = O; f[7][16] = O; f[8][16] = O; f[9][15] = O; f[9][16] = O
    f[5][16] = A; f[5][17] = A; f[6][17] = A; f[7][16] = A; f[7][17] = A
    return f
}()

// MARK: - Browsing frames (flipping notebook)

private let browsingFrame1: Frame = {
    var f = idleStand
    for r in 14...17 { f[r][8] = O; f[r][16] = O }
    f[15][7] = S; f[15][17] = S
    for r in 14...17 { f[r][7] = A; f[r][17] = A }
    for r in 14...17 { for c in 8...16 { if f[r][c] == O { f[r][c] = T } } }
    return f
}()

private let browsingFrame2: Frame = {
    var f = browsingFrame1
    f[14][8] = A
    return f
}()

// MARK: - Analyzing frames (wearing glasses)

private let analyzingFrame1: Frame = {
    var f = idleStand
    f[10][10] = A; f[10][12] = A
    f[9][11] = A; f[9][13] = A
    f[11][11] = A; f[11][13] = A
    return f
}()

private let analyzingFrame2: Frame = {
    var f = analyzingFrame1
    f[10][11] = S; f[10][13] = S
    f[11][11] = E; f[11][13] = E
    return f
}()

// MARK: - Celebrating frames (hands up)

private let celebrateFrame1: Frame = {
    var f = idleStand
    for r in 14...17 { f[r][8] = O; f[r][16] = O }
    f[11][7] = S; f[12][7] = S; f[13][8] = S
    f[11][17] = S; f[12][17] = S; f[13][16] = S
    f[10][11] = S; f[10][13] = S
    f[11][11] = E; f[11][13] = E
    return f
}()

private let celebrateFrame2: Frame = {
    var f = celebrateFrame1
    f[11][7] = O; f[11][17] = O
    f[10][7] = S; f[10][17] = S
    f[9][6] = A; f[9][18] = A
    return f
}()

// MARK: - Autopiloting frames (idle sprite + antenna/cap overlay)

/// Base autopilot pose — idle stand with an antenna drawn beside the
/// head. The antenna tip pulses in frame 2 to read as a transmission
/// blink at the existing 0.25s cadence. Positioned on the right side
/// of the head (col 15-16) so it stays well inside the 12-col crop
/// (cols 7-19) and doesn't clash with the sleepy-mood Z placement
/// (cols 15-17 at rows 5-9 — different mood, no visual conflict).
private let autopilotFrame1: Frame = {
    var f = idleStand
    // Antenna stalk rising from the right side of the head. Row 8 is
    // the top visible row in the crop; rows 9-10 straddle the top of
    // the head so the antenna reads as attached.
    f[8][15] = H
    f[9][15] = H
    // Antenna tip — two-pixel accent ball one row/col up and to the right
    f[8][16] = A
    return f
}()

/// Second frame — tip blinks off. Two-frame cycle matches the rest of
/// the mood set (most moods use 2-frame loops).
private let autopilotFrame2: Frame = {
    var f = autopilotFrame1
    f[8][16] = O
    return f
}()

// MARK: - Mood → Frame mapping

/// Memoized mood → frame table.
///
/// `framesForMood` used to build a fresh nested array every time it was
/// called, and `PixelBuddyView.body` called it on every evaluation — so every
/// re-render (and any SwiftUI re-layout, hover, mood flip, timer tick) rebuilt
/// up to 8 × 24 × 24 `PixelColor` values. The frames are immutable, so they are
/// now built once per mood and handed out by reference from a lock-guarded
/// cache. The lock keeps the `static` lazy init safe when the compact bar, the
/// expanded inbox and a test all ask for frames at the same moment.
enum PixelMoodFrames {
    private static let lock = NSLock()
    private static var cache: [BuddyMood: [Frame]] = [:]

    /// Number of moods whose frame table had to be *built*. A second request
    /// for the same mood is a cache hit and leaves this unchanged — the
    /// assertion the memoization test is written against.
    private(set) static var buildCount = 0

    /// The frames for `mood`, built at most once per process.
    static func frames(for mood: BuddyMood) -> [Frame] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[mood] { return cached }
        let built = PixelMoodFrames.build(mood)
        cache[mood] = built
        buildCount += 1
        return built
    }

    /// Frames currently in the cache. Never builds anything.
    static var cachedMoods: Set<BuddyMood> {
        lock.lock()
        defer { lock.unlock() }
        return Set(cache.keys)
    }

    /// How many frames `mood` animates through, without materialising the
    /// table (the driver only needs the count).
    static func frameCount(for mood: BuddyMood) -> Int { build(mood).count }

    /// The single place the frame literals are turned into a mood's cycle.
    private static func build(_ mood: BuddyMood) -> [Frame] {
        switch mood {
        case .idle:        return [idleStand, idleStand, idleBreathe, idleStand, idleBlink, idleStand, idleLookRight, idleStand]
        case .scanning:    return [scanFrame1, scanFrame2]
        case .pending:     return [pendingFrame1, pendingFrame2]
        case .urgent:      return [urgentFrame1, urgentFrame2]
        case .error:       return [errorFrame1, errorFrame2]
        case .sleepy:      return [sleepyFrame1, sleepyFrame2]
        case .browsing:    return [browsingFrame1, browsingFrame2]
        case .analyzing:   return [analyzingFrame1, analyzingFrame2]
        case .celebrating: return [celebrateFrame1, celebrateFrame2]
        case .autopiloting: return [autopilotFrame1, autopilotFrame2]
        }
    }
}

/// Mood → frame cycle. Kept as a free function for existing callers; the
/// result is memoized per mood (see `PixelMoodFrames`), so calling it in a
/// render pass no longer allocates a new table.
func framesForMood(_ mood: BuddyMood) -> [Frame] {
    PixelMoodFrames.frames(for: mood)
}

// MARK: - Sprite geometry

/// Crop region — only render the interesting part of the 24x24 grid.
/// Shared by the view and the pixel tests so both agree on the exact
/// mapping from grid cell → view point.
enum BuddySpriteGeometry {
    static let gridSize = 24
    static let cropTop = 8
    static let cropBottom = 20
    static let cropLeft = 7
    static let cropRight = 19
    static let cropRows = cropBottom - cropTop  // 12
    static let cropCols = cropRight - cropLeft  // 12
    /// Points per sprite pixel. 12 × 1.5 = 18pt, matching `IslandMetrics.buddy`.
    static let pixelSize: CGFloat = 1.5
}

/// One visible sprite pixel and where it lands in the view's coordinate space.
/// `BuddySpriteGeometry.pixelSize` is exactly representable in binary, so the
/// arithmetic here is exact and the rects tile without gaps or overlaps.
struct BuddyPixel: Equatable {
    let row: Int
    let col: Int
    let color: PixelColor
    /// A rectangle fully inside the sprite that this pixel covers.
    var rect: CGRect {
        CGRect(x: CGFloat(col) * BuddySpriteGeometry.pixelSize,
               y: CGFloat(row) * BuddySpriteGeometry.pixelSize,
               width: BuddySpriteGeometry.pixelSize,
               height: BuddySpriteGeometry.pixelSize)
    }
}

/// The crop → points mapping, as a pure function. The legacy renderer (144
/// `Rectangle`s in a nested `VStack`/`HStack`) and the `Canvas` renderer both
/// consume this list; the pixel tests compare the two bitmaps to prove the
/// swap did not move or recolour a single pixel.
enum PixelGridLayout {
    /// Visible pixels of `frame`, in row-major order. Transparent pixels are
    /// omitted — the legacy renderer drew them as fully transparent
    /// rectangles, which is a no-op over whatever is behind the sprite.
    static func pixels(in frame: Frame) -> [BuddyPixel] {
        var pixels: [BuddyPixel] = []
        pixels.reserveCapacity(BuddySpriteGeometry.cropRows * BuddySpriteGeometry.cropCols)
        for row in BuddySpriteGeometry.cropTop..<BuddySpriteGeometry.cropBottom {
            for col in BuddySpriteGeometry.cropLeft..<BuddySpriteGeometry.cropRight {
                let color = frame[row][col]
                guard color != .clear else { continue }
                pixels.append(BuddyPixel(row: row - BuddySpriteGeometry.cropTop,
                                         col: col - BuddySpriteGeometry.cropLeft,
                                         color: color))
            }
        }
        return pixels
    }

    /// Sprite size in points: 12 × 1.5 = 18.
    static var spriteSize: CGSize {
        CGSize(width: CGFloat(BuddySpriteGeometry.cropCols) * BuddySpriteGeometry.pixelSize,
               height: CGFloat(BuddySpriteGeometry.cropRows) * BuddySpriteGeometry.pixelSize)
    }
}

/// The sprite itself, drawn as a single `Canvas`.
///
/// The pre-Canvas view built 12 nested `HStack`s holding 144 `Rectangle`
/// views, and SwiftUI laid the whole tree out on every frame tick. A Canvas
/// draws the same 12×12 grid of 1.5pt cells in one pass: the content of each
/// cell is `BuddyPixel.rect` filled with `PixelColor.swiftUIColor`, which is
/// exactly what the old `Rectangle().fill(...)` painted.
struct BuddyPixelGrid: View {
    let frame: Frame
    var cellSize: CGFloat = BuddySpriteGeometry.pixelSize

    var body: some View {
        Canvas { context, _ in
            // One fill per colour instead of one per 1.5pt cell: the cells
            // never overlap, so a single path per colour paints exactly the
            // pixels 144 individual rectangles used to paint.
            var paths: [PixelColor: Path] = [:]
            for pixel in PixelGridLayout.pixels(in: frame) {
                paths[pixel.color, default: Path()].addRect(rect(for: pixel))
            }
            for (color, path) in paths {
                context.fill(path, with: .color(color.swiftUIColor))
            }
        }
        .frame(width: cellSize * CGFloat(BuddySpriteGeometry.cropCols),
               height: cellSize * CGFloat(BuddySpriteGeometry.cropRows))
    }

    /// Cell rect at the renderer's cell size. At the default size this is
    /// `BuddyPixel.rect`; the parameter exists so a test can render the same
    /// grid at a size that lands on whole device pixels.
    private func rect(for pixel: BuddyPixel) -> CGRect {
        CGRect(x: CGFloat(pixel.col) * cellSize,
               y: CGFloat(pixel.row) * cellSize,
               width: cellSize,
               height: cellSize)
    }
}

// MARK: - Lifecycle gate

/// Why the companion is allowed to animate, and why not.
///
/// The 0.55s frame timer used to run for the whole life of the view, including
/// while the panel was ordered out, the app was hidden, or the display was
/// asleep — the sprite kept cycling frames nothing could see. The gate names
/// the conditions; `CompanionFrameDriver` consults it before every advance.
enum CompanionFrameGate {
    enum Reason: Equatable {
        case ok
        case reduceMotion
        case appHidden
        case screenAsleep
        case panelOffScreen

        var isOpen: Bool { self == .ok }
    }

    /// Is the app's panel on screen? False when the panel is ordered out, in
    /// the Dock, or fully covered by another window — offscreen renders and
    /// unit tests (no app, no panel) also land here.
    ///
    /// `NSApp` is nil outside a running application, so this reads through an
    /// optional: the sprite must render (and stay still) in a test or preview
    /// without touching the live app.
    static func defaultPanelVisible() -> Bool {
        guard let app = NSApp, let panel = (app.delegate as? AppDelegate)?.panel else { return false }
        return panel.isVisible && !panel.isMiniaturized
            && panel.occlusionState.contains(.visible)
    }
}

/// Owns the 0.55s frame timer and the advance policy.
///
/// Extracted from the view so the gate has a unit-testable seam: the view
/// only says *what* the sprite looks like, the driver decides *whether* the
/// next frame may be shown (gate closed → stop the timer, keep the current
/// frame) and *when* the cycle wraps.
///
/// The four gate inputs are closures owned by the driver — deliberately not
/// globals, so a test can drive one driver without affecting the sprite in
/// the panel. Tests inject them; the app leaves them at the live system
/// values.
@MainActor
final class CompanionFrameDriver {
    /// Index of the frame being shown. Owned here so a tick mutates state the
    /// view renders from, instead of reaching back into the view.
    private(set) var frameIndex = 0
    /// Frames actually shown. The gating test asserts this stays 0 while the
    /// gate is closed.
    private(set) var appliedTicks = 0
    private(set) var frameCount: Int
    private(set) var isRunning = false
    private var timer: Timer?
    /// Interval the running timer was created with, so `start()` can tell
    /// "already ticking" from "needs arming".
    private var runningInterval: TimeInterval = 0
    /// The system asks for reduced motion (accessibility).
    var reduceMotionProvider: () -> Bool = { CompanionMotion.reduceMotion }
    /// The app itself is hidden (`NSApp.isHidden`).
    var appHiddenProvider: () -> Bool = { NSApp?.isHidden ?? false }
    /// The display is asleep. Set from `NSWorkspace.screensDidSleepNotification`
    /// / `screensDidWakeNotification` by the view.
    private var screenAsleep = false
    /// The surface hosting the sprite is on screen. Defaults to the app's
    /// panel (visible, not miniaturised, not fully covered); both sprites
    /// live in that one panel, so a single check covers them.
    var panelVisibleProvider: () -> Bool = CompanionFrameGate.defaultPanelVisible

    init(frameCount: Int) {
        self.frameCount = max(1, frameCount)
    }

    /// Why the sprite may or may not animate right now.
    var gateReason: CompanionFrameGate.Reason {
        if reduceMotionProvider() { return .reduceMotion }
        if appHiddenProvider() { return .appHidden }
        if screenAsleep { return .screenAsleep }
        if !panelVisibleProvider() { return .panelOffScreen }
        return .ok
    }

    var isGateOpen: Bool { gateReason.isOpen }

    /// Display sleep/wake. While the display is dark nothing is drawn, so the
    /// frame timer is dead weight.
    func setScreenAsleep(_ asleep: Bool) {
        guard screenAsleep != asleep else { return }
        screenAsleep = asleep
        refresh()
    }

    /// Re-evaluate the gate: arm the timer when it is open, park it when it
    /// is not. Called on every lifecycle signal (window show/hide, app
    /// hide/unhide, Reduce Motion, display sleep).
    func refresh() {
        if !isGateOpen { stop(); return }
        start()
    }

    /// Start ticking, or stop immediately when the gate is closed.
    func start(interval: TimeInterval = 0.55) {
        // A closed gate parks the timer right away rather than letting one
        // more tick go by.
        guard isGateOpen else {
            stop()
            return
        }
        // Idempotent: app-update notifications arrive several times a second,
        // and tearing the timer down on each one would restart the 0.55s
        // cycle every time — the sprite would never advance.
        if isRunning, runningInterval == interval { return }
        stop()
        isRunning = true
        self.runningInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` keeps the sprite cycling while the run loop is in a
        // tracking mode, which is when the old `.default`-mode timer went
        // quiet.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        runningInterval = 0
    }

    /// Updates the cycle length (the mood changed) and puts the sprite back
    /// on its first frame.
    func reset(frameCount: Int) {
        self.frameCount = max(1, frameCount)
        frameIndex = 0
    }

    /// One timer tick. Re-checks the gate because a tick can land between the
    /// gate closing and the notification that stops the timer.
    func tick() {
        guard isGateOpen else {
            stop()
            return
        }
        frameIndex = (frameIndex + 1) % frameCount
        appliedTicks += 1
    }
}

// MARK: - Pixel Buddy View

/// The 18pt companion mark, drawn as a single `Canvas` and animated by
/// `CompanionFrameDriver`. The frame table is memoized per mood; the timer
/// only runs while the sprite is actually visible (see `CompanionFrameGate`).
struct PixelBuddyView: View {
    let mood: BuddyMood
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The timer lives in the view's state (not in the view value), so a
    /// SwiftUI re-render does not restart it.
    @State private var driver = CompanionFrameDriver(
        frameCount: PixelMoodFrames.frameCount(for: .idle)
    )

    private var frames: [Frame] { framesForMood(mood) }

    var body: some View {
        // Reading `frames` (not just the count) is what exercises the
        // memoized table, and keeps the view in sync with a mood flip.
        let cycle = frames
        let visible = cycle[driver.frameIndex % cycle.count]

        BuddyPixelGrid(frame: visible)
            .accessibilityHidden(true)
            .onChange(of: mood) {
                driver.reset(frameCount: cycle.count)
                restartTimer()
            }
            .onChange(of: reduceMotion) { restartTimer() }
            // Panel visibility, app hide/unhide and display sleep all land
            // as an app update; re-asking the gate here is what stops the
            // timer when the panel is ordered out and restarts it when the
            // panel comes back.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didUpdateNotification)
            ) { _ in restartTimer() }
            // Ticks cannot observe display sleep (nothing is drawn while the
            // panel is dark); the notification is the only signal.
            .onReceive(NotificationCenter.default.publisher(
                for: NSWorkspace.screensDidSleepNotification)
            ) { _ in
                driver.setScreenAsleep(true)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSWorkspace.screensDidWakeNotification)
            ) { _ in
                driver.setScreenAsleep(false)
            }
            .onAppear { restartTimer() }
            .onDisappear {
                driver.stop()
            }
    }

    /// (Re)start the timer when the gate is open. When the gate is closed,
    /// `driver.start()` invalidates the timer and leaves the sprite on its
    /// current frame.
    private func restartTimer() { driver.start() }
}
