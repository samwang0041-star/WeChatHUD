import SwiftUI

struct InsightHeroSection: View {
    let briefing: GlobalBriefing?
    var generatedAt: Date? = nil
    var now: Date = Date()
    let isLoading: Bool
    let onGenerate: () -> Void

    var body: some View {
        if let briefing = briefing {
            briefingHero(briefing)
        } else {
            ctaHero
        }
    }

    private func briefingHero(_ briefing: GlobalBriefing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text(InsightBriefingCaption.text(generatedAt: generatedAt, now: now))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Spacer()
                if !briefing.overallMood.isEmpty {
                    Text(briefing.overallMood)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            Text(briefing.headline)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !briefing.topSuggestion.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .padding(.top, 2)
                    Text(briefing.topSuggestion)
                        .font(.system(size: 12))
                        .foregroundColor(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !briefing.blindSpots.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text("盲区提醒")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(briefing.blindSpots.prefix(3), id: \.self) { spot in
                        HStack(alignment: .top, spacing: 4) {
                            Text("•")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(spot)
                                .font(.system(size: 11))
                                .foregroundColor(.primary.opacity(0.8))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.12), Color.accentColor.opacity(0.04)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
        )
    }

    /// States the rule instead of a count: the number the generation actually
    /// reads is today's watched chats, while `overview.totalMessages` follows
    /// the scope/window the page is showing (default 所有人), so the two could
    /// never agree.
    private var ctaHero: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: WorkspaceType.title))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("生成今日摘要")
                    .workspaceRowTitle()
                Text("把已关注对话今天的聊天，汇总成待办和跨对话话题")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: onGenerate) {
                Text(isLoading ? "正在分析…" : "开始分析")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .tint(CompanionPalette.accent)
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)
            .help(isLoading ? "正在汇总今天的聊天" : "")
            .accessibilityHint(isLoading ? "正在汇总今天的聊天" : "")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
        .cornerRadius(10)
    }
}

/// The briefing card's freshness label.
///
/// `briefing.date` is the model's free-text 「日期」 — it can be a full
/// ISO8601 stamp, `2026-09-18`, or prose, so it is not something to print as a
/// timestamp. When *we* produced the briefing is a local fact, and it is the
/// number the 30-minute refresh window actually turns on.
enum InsightBriefingCaption {
    static func text(generatedAt: Date?, now: Date = Date()) -> String {
        guard let generatedAt else { return "AI 摘要" }
        let waited = now.timeIntervalSince(generatedAt)
        if waited < 60 { return "AI 摘要 · 刚刚更新" }
        if waited < 3600 { return "AI 摘要 · \(Int(waited / 60)) 分钟前更新" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        // Compared against the injected clock, not the real calendar day.
        if Calendar.current.isDate(generatedAt, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return "AI 摘要 · 今天 \(formatter.string(from: generatedAt)) 更新"
        }
        formatter.dateFormat = "M月d日"
        return "AI 摘要 · \(formatter.string(from: generatedAt)) 更新"
    }
}
