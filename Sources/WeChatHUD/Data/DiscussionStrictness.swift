import Foundation

/// How much of the extracted material reaches the user as "work".
///
/// The extractor writes five kinds of item into one table: things to do,
/// questions waiting on an answer, decisions, and two kinds of pure record
/// (`info`, `timePlace`). On a real corpus most of what accumulated was
/// record-keeping, not work — half of the pending list was `info`, and all
/// of it competed for the same attention as a real task.
///
/// The level decides which of those the task surfaces show. It is applied
/// when reading, never when writing: extraction keeps storing everything, so
/// moving the level is instant, free, and reversible in both directions.
///
/// The knob is deliberately *not* a confidence threshold. Confidence on this
/// corpus is saturated (94% of rows sit at 0.8–0.9) and correlates with the
/// wrong thing: a factual statement ("预算 30 万") scores high while a real
/// task ("方案发我") scores lower, so tightening confidence deletes work and
/// keeps trivia. Kind and owner are what actually separate the two.
enum DiscussionStrictness: String, Codable, CaseIterable, Sendable {
    /// Everything extracted, records included.
    case everything
    /// Default. Records step aside; anything with a task shape stays.
    case actionable
    /// Only work with a side attached, or a deadline inside the window.
    case pressing

    /// How far ahead a dated item counts as pressing.
    static let pressingWindow: TimeInterval = 7 * 24 * 60 * 60

    static let `default`: DiscussionStrictness = .actionable

    /// Decoding is lenient on purpose: an unknown or newer value must not
    /// blank the task list, and a missing key means "user never chose".
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DiscussionStrictness(rawValue: raw) ?? .default
    }

    var label: String {
        switch self {
        case .everything: return "全部都记"
        case .actionable: return "只留要做的"
        case .pressing: return "只留压在我身上的"
        }
    }

    var explanation: String {
        switch self {
        case .everything:
            return "信息点和时间地点也留在列表里。适合想回看聊过什么的时候。"
        case .actionable:
            return "信息点、时间地点这些只算记录的内容收进「信息备忘」，不占待办列表。"
        case .pressing:
            return "只留你或对方明确要交付的事，以及 7 天内到期的事。最干净，也最容易漏。"
        }
    }

    /// Whether one item is part of the work queue at this level.
    func admits(_ item: DiscussionItem, now: Date = Date()) -> Bool {
        guard item.status == .pending else { return false }
        return admits(kind: item.kind, owner: item.owner, dueAt: item.dueAt, now: now)
    }

    func admits(kind: DiscussionItemKind, owner: DiscussionItemOwner, dueAt: Date?, now: Date = Date()) -> Bool {
        switch self {
        case .everything:
            return true
        case .actionable:
            // `timePlace` reads like a record ("明天下午 3 点，老地方") and was
            // being shown as work. It stays in the memo tab, where it is still
            // searchable, but it no longer pads the task list.
            return kind != .info && kind != .timePlace
        case .pressing:
            // Records stay out at this level too. Admitting them here because
            // they happen to be dated would make the tighter level *looser*
            // than the one above it — an item that disappears when you
            // tighten and reappears when you loosen is a lie about ordering.
            guard kind != .info, kind != .timePlace else { return false }
            // Work with a side attached is pressing whenever it is due.
            if kind == .todo || kind == .decision, owner == .mine || owner == .theirs {
                return true
            }
            // Otherwise the date is what makes it pressing.
            guard let dueAt else { return false }
            return dueAt <= now.addingTimeInterval(Self.pressingWindow)
        }
    }

    /// Items this level keeps out of the task list, for the "已收起 N 条"
    /// receipt. Without it a tighter level silently loses rows and the user
    /// cannot tell whether the data is hidden or gone.
    func hidden(from items: [DiscussionItem], now: Date = Date()) -> [DiscussionItem] {
        items.filter { $0.status == .pending && !admits($0, now: now) }
    }
}

/// Persisted shape. A wrapper rather than a bare string so the setting can
/// gain fields later without another key, and so decoding stays lenient.
struct DiscussionStrictnessSetting: Codable, Equatable, Sendable {
    var level: DiscussionStrictness = .default
}

enum DiscussionStrictnessPolicy {
    static let settingKey = "discussionStrictness"
}
