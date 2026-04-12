import SwiftUI

// MARK: - Shared helpers

private func moodColor(_ mood: String) -> Color {
    let m = mood.lowercased()
    if m.contains("积极") || m.contains("正面") || m.contains("高兴") || m.contains("满意") {
        return .green
    }
    if m.contains("消极") || m.contains("不满") || m.contains("愤怒") || m.contains("焦虑") {
        return .red
    }
    if m.contains("紧张") || m.contains("担忧") || m.contains("压力") {
        return .orange
    }
    return .white.opacity(0.5)
}

// MARK: - VIP Insight Card (expandable)

/// Full VIP analysis card shown below a MessageRow when the user taps a
/// VIP notification that has a loaded `VIPAggregator.AggregateResult`.
struct VIPInsightCardView: View {
    let insight: VIPAggregator.AggregateResult
    let vipName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .background(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 6) {
                // Summary header
                if !insight.summary.isEmpty {
                    Text(insight.summary)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                // Involves user callout
                if insight.involvesUser, let detail = insight.involveDetail, !detail.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "person.fill.questionmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.yellow)
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(.yellow.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.1))
                    .cornerRadius(4)
                }

                // Mood section
                if !insight.mood.isEmpty {
                    insightSection(label: "情绪趋势") {
                        HStack(spacing: 5) {
                            moodDot(insight.mood)
                            Text(insight.mood)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                            if !insight.moodEvidence.isEmpty {
                                Text("·")
                                    .foregroundColor(.white.opacity(0.3))
                                Text(insight.moodEvidence)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.65))
                            }
                        }
                        if !insight.moodTrendAnalysis.isEmpty {
                            Text(insight.moodTrendAnalysis)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // Recommended action section
                if !insight.recommendedAction.isEmpty {
                    insightSection(label: "建议行动") {
                        Text(insight.recommendedAction)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                        if !insight.actionTiming.isEmpty {
                            Text(insight.actionTiming)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                }

                // Key topics chips
                if !insight.keyTopics.isEmpty {
                    insightSection(label: "关键话题") {
                        FlowLayout(spacing: 4) {
                            ForEach(insight.keyTopics, id: \.self) { topic in
                                topicChip(topic)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Color.white.opacity(0.04))
    }

    // MARK: - Section wrapper

    private func insightSection<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
            content()
        }
    }

    // MARK: - Mood dot

    private func moodDot(_ mood: String) -> some View {
        Circle()
            .fill(moodColor(mood))
            .frame(width: 6, height: 6)
    }

    // MARK: - Topic chip

    private func topicChip(_ topic: String) -> some View {
        Text(topic)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.1))
            .cornerRadius(3)
    }
}

// MARK: - VIP Inline Tags (compact badges for message rows)

/// Small inline tags shown directly in a VIP MessageRow.
/// Renders the mood state and urgency level at a glance.
struct VIPInlineTags: View {
    let insight: VIPAggregator.AggregateResult

    var body: some View {
        HStack(spacing: 3) {
            if !insight.mood.isEmpty {
                moodTag(insight.mood)
            }
            if insight.urgency == "high" || insight.urgency == "urgent" {
                urgencyTag
            }
        }
    }

    // MARK: - Mood tag

    private func moodTag(_ mood: String) -> some View {
        let color = moodColor(mood)
        return Text(mood)
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(3)
    }

    private var urgencyTag: some View {
        Text("紧急")
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(.red)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.15))
            .cornerRadius(3)
    }

}

// MARK: - FlowLayout helper

/// Simple left-to-right wrapping layout for keyword chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
                totalHeight = y
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
