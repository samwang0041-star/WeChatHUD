# Pixel Buddy Mascot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 24x24 pixel art companion character to CompactInboxBar and InboxView that reacts to app state with 9 different moods/animations.

**Architecture:** Single `PixelBuddyView` using SwiftUI Canvas to render pixel grids, driven by a `BuddyMood` enum. Frame animation via Timer at ~4fps. Mood derived from ChatMonitor state at each call site.

**Tech Stack:** SwiftUI (Canvas, Path, Timer), no external dependencies.

**Spec:** `docs/superpowers/specs/2026-04-13-pixel-buddy-mascot-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `Sources/WeChatHUD/Views/PixelBuddyView.swift` | BuddyMood enum, PixelColor enum, frame data, Canvas rendering, Timer animation |
| Create | `Tests/WeChatHUDTests/PixelBuddyTests.swift` | BuddyMood derivation tests |
| Modify | `Sources/WeChatHUD/Views/CompactInboxBar.swift` | Add PixelBuddyView to right end, mood derivation, sleepy tracking |
| Modify | `Sources/WeChatHUD/Views/InboxView.swift` | Add PixelBuddyView to header, extended mood derivation |

---

### Task 1: PixelColor enum and BuddyMood enum

**Files:**
- Create: `Sources/WeChatHUD/Views/PixelBuddyView.swift`
- Create: `Tests/WeChatHUDTests/PixelBuddyTests.swift`

- [ ] **Step 1: Create PixelBuddyView.swift with enums and mood derivation helper**

```swift
// Sources/WeChatHUD/Views/PixelBuddyView.swift
import SwiftUI

// MARK: - Pixel Color Palette

enum PixelColor: UInt32 {
    case clear  = 0x00000000
    case skin   = 0xFFD4A574
    case hair   = 0xFF2C2C2C
    case shirt  = 0xFF4A90D9
    case pants  = 0xFF3C3C3C
    case eye    = 0xFF1A1A1A
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

enum BuddyMood: CaseIterable {
    case idle
    case scanning
    case pending
    case urgent
    case error
    case sleepy
    case browsing
    case analyzing
    case celebrating
}

// MARK: - Mood Derivation (pure function for testability)

/// Derive compact-bar mood from sync status and inbox items.
/// Priority: syncing > error > urgent > pending > idle
func deriveCompactMood(syncStatus: SyncStatus, hasUrgent: Bool, hasPending: Bool, idleMinutes: Int) -> BuddyMood {
    switch syncStatus {
    case .syncing:
        return .scanning
    case .stale, .waitingForWeChat, .error:
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
```

- [ ] **Step 2: Write tests for mood derivation**

```swift
// Tests/WeChatHUDTests/PixelBuddyTests.swift
import XCTest
@testable import WeChatHUD

final class PixelBuddyTests: XCTestCase {

    // MARK: - Compact mood derivation

    func testCompactMood_syncing_returnScanning() {
        let mood = deriveCompactMood(syncStatus: .syncing, hasUrgent: false, hasPending: false, idleMinutes: 0)
        XCTAssertEqual(mood, .scanning)
    }

    func testCompactMood_syncError_returnsError() {
        let mood = deriveCompactMood(syncStatus: .error("fail"), hasUrgent: true, hasPending: true, idleMinutes: 0)
        XCTAssertEqual(mood, .error, "error takes priority over urgent")
    }

    func testCompactMood_waitingForWeChat_returnsError() {
        let mood = deriveCompactMood(syncStatus: .waitingForWeChat, hasUrgent: false, hasPending: false, idleMinutes: 0)
        XCTAssertEqual(mood, .error)
    }

    func testCompactMood_stale_returnsError() {
        let mood = deriveCompactMood(syncStatus: .stale, hasUrgent: false, hasPending: false, idleMinutes: 0)
        XCTAssertEqual(mood, .error)
    }

    func testCompactMood_urgent_returnsUrgent() {
        let mood = deriveCompactMood(syncStatus: .ok, hasUrgent: true, hasPending: true, idleMinutes: 0)
        XCTAssertEqual(mood, .urgent, "urgent takes priority over pending")
    }

    func testCompactMood_pending_returnsPending() {
        let mood = deriveCompactMood(syncStatus: .ok, hasUrgent: false, hasPending: true, idleMinutes: 0)
        XCTAssertEqual(mood, .pending)
    }

    func testCompactMood_idle5min_returnsSleepy() {
        let mood = deriveCompactMood(syncStatus: .ok, hasUrgent: false, hasPending: false, idleMinutes: 5)
        XCTAssertEqual(mood, .sleepy)
    }

    func testCompactMood_idle3min_returnsIdle() {
        let mood = deriveCompactMood(syncStatus: .ok, hasUrgent: false, hasPending: false, idleMinutes: 3)
        XCTAssertEqual(mood, .idle)
    }

    // MARK: - Extended mood derivation

    func testExtendedMood_emptyInbox_returnsCelebrating() {
        let mood = deriveExtendedMood(actionItemCount: 0, isAIProcessing: false)
        XCTAssertEqual(mood, .celebrating)
    }

    func testExtendedMood_aiProcessing_returnsAnalyzing() {
        let mood = deriveExtendedMood(actionItemCount: 3, isAIProcessing: true)
        XCTAssertEqual(mood, .analyzing)
    }

    func testExtendedMood_hasItems_returnsBrowsing() {
        let mood = deriveExtendedMood(actionItemCount: 3, isAIProcessing: false)
        XCTAssertEqual(mood, .browsing)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter PixelBuddyTests 2>&1 | tail -20`
Expected: Build error — `PixelBuddyView.swift` not yet in target / BuddyMood not Equatable.

- [ ] **Step 4: Make BuddyMood Equatable and verify tests pass**

Add `Equatable` conformance to `BuddyMood`:

```swift
enum BuddyMood: CaseIterable, Equatable {
```

Run: `swift test --filter PixelBuddyTests 2>&1 | tail -20`
Expected: 11 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Views/PixelBuddyView.swift Tests/WeChatHUDTests/PixelBuddyTests.swift
git commit -m "feat(buddy): add BuddyMood/PixelColor enums with mood derivation + tests"
```

---

### Task 2: Pixel art frame data

**Files:**
- Modify: `Sources/WeChatHUD/Views/PixelBuddyView.swift`

Each frame is a 24x24 grid. We use short aliases to keep frames readable.
The character is a simple humanoid: 4px head, 2px neck area, 6px torso, 6px legs, standing on a 24-wide canvas centered around columns 8-15.

- [ ] **Step 1: Add frame data type alias and idle frames**

Add after the `deriveExtendedMood` function:

```swift
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
    // Widen torso by 1px each side on row 16
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
```

- [ ] **Step 2: Add remaining mood frames**

Append after idle frames:

```swift
// MARK: - Scanning frames (holding magnifying glass)

private let scanFrame1: Frame = {
    var f = idleStand
    // Right arm raised (cols 16-17, rows 12-14) holding glass
    for r in 14...17 { f[r][16] = O }  // remove resting arm
    f[12][16] = S; f[13][16] = S; f[13][17] = S  // arm up
    // Magnifying glass (accent circle at top-right)
    f[11][17] = A; f[11][18] = A; f[12][18] = A; f[12][17] = A
    return f
}()

private let scanFrame2: Frame = {
    var f = scanFrame1
    // Tilt glass slightly — shift glass up 1
    f[12][17] = O; f[12][18] = O
    f[10][17] = A; f[10][18] = A
    return f
}()

// MARK: - Pending frames (waving a flag)

private let pendingFrame1: Frame = {
    var f = idleStand
    // Right arm up holding flag
    for r in 14...17 { f[r][16] = O }
    f[11][16] = S; f[12][16] = S; f[13][16] = S  // arm up
    // Flag (accent)
    f[9][17] = A; f[9][18] = A; f[10][17] = A; f[10][18] = A
    return f
}()

private let pendingFrame2: Frame = {
    var f = pendingFrame1
    // Flag wave — shift flag pixels
    f[9][18] = O; f[10][18] = O
    f[9][19] = A; f[10][19] = A
    return f
}()

// MARK: - Urgent frames (jumping + exclamation mark)

private let urgentFrame1: Frame = {
    // Shift entire character up by 2 rows (jumping)
    var f = Array(repeating: Array(repeating: O, count: 24), count: 24)
    // Copy idleStand but shifted up 2
    for r in 0..<22 {
        for c in 0..<24 {
            if r + 2 < 24 { f[r][c] = idleStand[r + 2][c] }
        }
    }
    // Exclamation mark above head (accent)
    f[2][12] = A; f[3][12] = A; f[5][12] = A
    return f
}()

private let urgentFrame2: Frame = {
    // Back on ground, exclamation still showing
    var f = idleStand
    f[3][12] = A; f[4][12] = A
    return f
}()

// MARK: - Error frames (crouching + question mark)

private let errorFrame1: Frame = {
    var f = Array(repeating: Array(repeating: O, count: 24), count: 24)
    // Shift body down 2 rows (crouching)
    for r in 2..<24 {
        for c in 0..<24 { f[r][c] = idleStand[r - 2][c] }
    }
    // Clear legs below (crouched)
    for r in 22...23 { for c in 0..<24 { f[r][c] = O } }
    // Question mark above
    f[6][12] = A; f[6][13] = A; f[7][13] = A; f[8][12] = A; f[10][12] = A
    return f
}()

private let errorFrame2: Frame = {
    var f = errorFrame1
    // Blink question mark
    f[10][12] = O
    return f
}()

// MARK: - Sleepy frames (sitting, Z's)

private let sleepyFrame1: Frame = {
    var f = Array(repeating: Array(repeating: O, count: 24), count: 24)
    // Sitting pose — body lower, legs horizontal
    // Head (rows 10-13)
    for c in 10...14 { f[10][c] = H; f[11][c] = H }
    for r in 12...15 { for c in 10...14 { f[r][c] = S } }
    f[13][11] = E; f[13][13] = S  // one eye closed (sleepy)
    // Torso (rows 16-19)
    for r in 16...19 { for c in 9...15 { f[r][c] = T } }
    // Legs out horizontal (rows 20-21, cols 10-17)
    for c in 10...17 { f[20][c] = P; f[21][c] = P }
    // Z above head
    f[7][15] = A; f[7][16] = A; f[8][16] = A; f[9][15] = A; f[9][16] = A
    return f
}()

private let sleepyFrame2: Frame = {
    var f = sleepyFrame1
    // Z floats up
    f[7][15] = O; f[7][16] = O; f[8][16] = O; f[9][15] = O; f[9][16] = O
    f[5][16] = A; f[5][17] = A; f[6][17] = A; f[7][16] = A; f[7][17] = A
    return f
}()

// MARK: - Browsing frames (flipping notebook)

private let browsingFrame1: Frame = {
    var f = idleStand
    // Both arms forward holding book
    for r in 14...17 { f[r][8] = O; f[r][16] = O }
    f[15][7] = S; f[15][17] = S
    // Notebook in front (accent)
    for r in 14...17 { f[r][7] = A; f[r][17] = A }
    for r in 14...17 { for c in 8...16 { if f[r][c] == O { f[r][c] = T } } }
    return f
}()

private let browsingFrame2: Frame = {
    var f = browsingFrame1
    // Page flip — one accent pixel moves
    f[14][8] = A
    return f
}()

// MARK: - Analyzing frames (wearing glasses)

private let analyzingFrame1: Frame = {
    var f = idleStand
    // Glasses on face (accent circles around eyes)
    f[10][10] = A; f[10][12] = A  // glass frames
    f[9][11] = A; f[9][13] = A    // top rim
    f[11][11] = A; f[11][13] = A  // bottom rim
    return f
}()

private let analyzingFrame2: Frame = {
    var f = analyzingFrame1
    // Look down slightly — eyes shift down
    f[10][11] = S; f[10][13] = S
    f[11][11] = E; f[11][13] = E
    return f
}()

// MARK: - Celebrating frames (hands up)

private let celebrateFrame1: Frame = {
    var f = idleStand
    // Both arms raised up
    for r in 14...17 { f[r][8] = O; f[r][16] = O }
    f[11][7] = S; f[12][7] = S; f[13][8] = S  // left arm up
    f[11][17] = S; f[12][17] = S; f[13][16] = S  // right arm up
    // Happy eyes (curved)
    f[10][11] = S; f[10][13] = S  // close eyes (happy)
    f[11][11] = E; f[11][13] = E  // smile eyes lower
    return f
}()

private let celebrateFrame2: Frame = {
    var f = celebrateFrame1
    // Arms even higher
    f[11][7] = O; f[11][17] = O
    f[10][7] = S; f[10][17] = S
    // Star accents near hands
    f[9][6] = A; f[9][18] = A
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
    }
}
```

- [ ] **Step 3: Verify build compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded.

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Views/PixelBuddyView.swift
git commit -m "feat(buddy): add pixel art frame data for all 9 moods"
```

---

### Task 3: PixelBuddyView Canvas rendering + Timer animation

**Files:**
- Modify: `Sources/WeChatHUD/Views/PixelBuddyView.swift`

- [ ] **Step 1: Add PixelBuddyView struct**

Append at the end of `PixelBuddyView.swift`:

```swift
// MARK: - Pixel Buddy View

struct PixelBuddyView: View {
    let mood: BuddyMood

    @State private var frameIndex = 0
    @State private var timer: Timer?

    private var frames: [Frame] { framesForMood(mood) }

    var body: some View {
        Canvas { context, size in
            let currentFrame = frames[frameIndex % frames.count]
            let pixelW = size.width / 24
            let pixelH = size.height / 24
            for row in 0..<min(currentFrame.count, 24) {
                let cols = currentFrame[row]
                for col in 0..<min(cols.count, 24) {
                    let color = cols[col]
                    guard color != .clear else { continue }
                    let rect = CGRect(
                        x: CGFloat(col) * pixelW,
                        y: CGFloat(row) * pixelH,
                        width: pixelW,
                        height: pixelH
                    )
                    context.fill(Path(rect), with: .color(color.swiftUIColor))
                }
            }
        }
        .frame(width: 24, height: 24)
        .onChange(of: mood) { _ in
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
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded.

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Views/PixelBuddyView.swift
git commit -m "feat(buddy): add PixelBuddyView with Canvas rendering and Timer animation"
```

---

### Task 4: Integrate into CompactInboxBar

**Files:**
- Modify: `Sources/WeChatHUD/Views/CompactInboxBar.swift:11-140`

- [ ] **Step 1: Add buddy mood derivation and sleepy tracking**

In `CompactInboxBar`, add state and computed property:

```swift
// Add inside CompactInboxBar struct, before `body`:
@State private var idleSince: Date? = nil
@State private var idleMinutes: Int = 0
@State private var idleTimer: Timer? = nil
```

Add computed property after `syncErrorText`:

```swift
private var buddyMood: BuddyMood {
    let actionItems = monitor.inboxItems.filter { $0.actionRequired }
    let hasUrgent = actionItems.contains { $0.priority == .p0 }
    let hasPending = !actionItems.isEmpty
    return deriveCompactMood(
        syncStatus: monitor.stats.syncStatus,
        hasUrgent: hasUrgent,
        hasPending: hasPending,
        idleMinutes: idleMinutes
    )
}
```

- [ ] **Step 2: Add PixelBuddyView to the HStack**

Change the `body` from:

```swift
var body: some View {
    HStack(spacing: 6) {
        statusContent
        Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

To:

```swift
var body: some View {
    HStack(spacing: 6) {
        statusContent
        Spacer(minLength: 0)
        PixelBuddyView(mood: buddyMood)
            .padding(.trailing, 2)
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
        idleSince = Date()
        startIdleTimer()
    }
    .onDisappear {
        idleTimer?.invalidate()
        idleTimer = nil
    }
}
```

- [ ] **Step 3: Add idle timer logic**

Add after `syncErrorText`:

```swift
private func startIdleTimer() {
    idleTimer?.invalidate()
    idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
        DispatchQueue.main.async {
            let baseMood = deriveCompactMood(
                syncStatus: monitor.stats.syncStatus,
                hasUrgent: monitor.inboxItems.contains { $0.priority == .p0 },
                hasPending: monitor.inboxItems.contains { $0.actionRequired },
                idleMinutes: 0
            )
            if baseMood == .idle {
                if let since = idleSince {
                    idleMinutes = Int(Date().timeIntervalSince(since) / 60)
                }
            } else {
                idleSince = Date()
                idleMinutes = 0
            }
        }
    }
}
```

- [ ] **Step 4: Widen compact bar to accommodate buddy**

In `compactBarWidth()` at the bottom of the file, change:

```swift
func compactBarWidth(inboxItems: [InboxItem], syncStatus: SyncStatus) -> CGFloat {
    let hasUrgent = inboxItems.contains { $0.priority != .p2 }
    if hasUrgent { return 380 }
    if !inboxItems.isEmpty { return 240 }
    return 200
}
```

To:

```swift
func compactBarWidth(inboxItems: [InboxItem], syncStatus: SyncStatus) -> CGFloat {
    let hasUrgent = inboxItems.contains { $0.priority != .p2 }
    if hasUrgent { return 410 }
    if !inboxItems.isEmpty { return 270 }
    return 230
}
```

- [ ] **Step 5: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded.

- [ ] **Step 6: Run all tests to check no regressions**

Run: `swift test 2>&1 | grep -E "(Test Suite|Tests/|passed|failed)"`
Expected: All existing tests + PixelBuddyTests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/WeChatHUD/Views/CompactInboxBar.swift
git commit -m "feat(buddy): integrate PixelBuddyView into CompactInboxBar with mood derivation"
```

---

### Task 5: Integrate into InboxView header

**Files:**
- Modify: `Sources/WeChatHUD/Views/InboxView.swift:65-94`

- [ ] **Step 1: Add extended mood derivation**

Add a computed property inside `InboxView`:

```swift
private var extendedBuddyMood: BuddyMood {
    let actionCount = monitor.inboxItems.filter { $0.actionRequired }.count
    // ChatMonitor doesn't expose a single "isAIProcessing" bool,
    // so we use syncStatus == .syncing as a proxy
    let isProcessing = monitor.stats.syncStatus == .syncing
    return deriveExtendedMood(actionItemCount: actionCount, isAIProcessing: isProcessing)
}
```

- [ ] **Step 2: Add PixelBuddyView to header**

Change the header from (lines 67-90):

```swift
return HStack(spacing: 6) {
    Spacer()
    if let syncAt = monitor.stats.lastSyncAt {
        Text(syncLabel(syncAt))
            .font(.system(size: 9))
            .foregroundColor(.white.opacity(0.25))
    }
    if actionCount > 0 {
        Text("\(actionCount)")
            .font(.system(size: 9, weight: .bold))
            .monospacedDigit()
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.red)
            .cornerRadius(3)
    }
    Button(action: { panelState.showDetail() }) {
        Image(systemName: "gearshape.fill")
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.5))
    }
    .buttonStyle(.plain)
}
```

To:

```swift
return HStack(spacing: 6) {
    Spacer()
    PixelBuddyView(mood: extendedBuddyMood)
    if let syncAt = monitor.stats.lastSyncAt {
        Text(syncLabel(syncAt))
            .font(.system(size: 9))
            .foregroundColor(.white.opacity(0.25))
    }
    if actionCount > 0 {
        Text("\(actionCount)")
            .font(.system(size: 9, weight: .bold))
            .monospacedDigit()
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.red)
            .cornerRadius(3)
    }
    Button(action: { panelState.showDetail() }) {
        Image(systemName: "gearshape.fill")
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.5))
    }
    .buttonStyle(.plain)
}
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded.

- [ ] **Step 4: Run all tests**

Run: `swift test 2>&1 | grep -E "(Test Suite|Tests/|passed|failed)"`
Expected: All tests pass (194 existing + 11 new PixelBuddyTests).

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Views/InboxView.swift
git commit -m "feat(buddy): integrate PixelBuddyView into InboxView header"
```

---

### Task 6: Manual visual verification

- [ ] **Step 1: Build and run the app**

Run: `make app && make run`

- [ ] **Step 2: Verify compact bar**

Check that:
- Pixel buddy appears at the right end of the compact bar
- Idle animation plays (breathing, blinking)
- Bar width accommodates the buddy without clipping

- [ ] **Step 3: Verify extended inbox**

Click to expand inbox and check that:
- Pixel buddy appears in the header row
- Mood matches current state (browsing if items present, celebrating if empty)

- [ ] **Step 4: Fix any visual issues found during testing**

Adjust pixel art, sizing, or positioning as needed.

- [ ] **Step 5: Final commit if any fixes were made**

```bash
git add -u
git commit -m "fix(buddy): visual adjustments from manual testing"
```
