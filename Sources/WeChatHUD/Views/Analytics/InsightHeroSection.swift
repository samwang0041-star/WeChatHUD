import SwiftUI

struct InsightHeroSection: View {
    let overview: ChatInsightEngine.GlobalOverview
    let briefing: GlobalBriefing?
    let isLoading: Bool
    let onGenerate: () -> Void

    var body: some View {
        if let briefing = briefing {
            briefingHero(briefing)
        } else {
            ctaHero(overview: overview)
        }
    }

    private func briefingHero(_ briefing: GlobalBriefing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text("AI 全景总结 · \(briefing.date)")
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

    private func ctaHero(overview: ChatInsightEngine.GlobalOverview) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("生成 AI 全景总结")
                    .font(.system(size: 13, weight: .semibold))
                Text("基于 \(overview.totalMessages) 条消息，AI 会提炼需要你行动的事、跨对话话题、暗信号等")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: onGenerate) {
                Text("开始分析")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
        .cornerRadius(10)
    }
}
