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
                    withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
                }

            if isHovering {
                activityPanel(now: now)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .offset(y: 22)
                    .zIndex(1)
            }
        }
        .onAppear { startRefresh() }
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
/// Priority: syncing > error > urgent > pending > idle
func deriveCompactMood(syncStatus: SyncStatus, hasUrgent: Bool, hasPending: Bool, idleMinutes: Int) -> BuddyMood {
    switch syncStatus {
    case .syncing:
        return .scanning
    case .stale, .waitingForWeChat, .error, .accountSwitched:
        return .error
    default:
        break
    }
    if hasUrgent { return .urgent }
    if hasPending { return .pending }
    if idleMinutes >= 5 { return .sleepy }
    return .idle
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

func framesForMood(_ mood: BuddyMood) -> [Frame] {
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

// MARK: - Pixel Buddy View

struct PixelBuddyView: View {
    let mood: BuddyMood

    /// Crop region — only render the interesting part of the 24x24 grid
    private static let cropTop = 8
    private static let cropBottom = 20
    private static let cropLeft = 7
    private static let cropRight = 19
    private static let cropRows = cropBottom - cropTop  // 12
    private static let cropCols = cropRight - cropLeft  // 12

    @State private var frameIndex = 0
    @State private var timer: Timer?

    private var frames: [Frame] { framesForMood(mood) }

    var body: some View {
        let currentFrame = frames[frameIndex % frames.count]
        let pxSize: CGFloat = 1.5  // each pixel = 1.5pt

        VStack(spacing: 0) {
            ForEach(Self.cropTop..<Self.cropBottom, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(Self.cropLeft..<Self.cropRight, id: \.self) { col in
                        let color = currentFrame[row][col]
                        Rectangle()
                            .fill(color.swiftUIColor)
                            .frame(width: pxSize, height: pxSize)
                    }
                }
            }
        }
        .onChange(of: mood) {
            frameIndex = 0
        }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            DispatchQueue.main.async {
                frameIndex = (frameIndex + 1) % frames.count
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
