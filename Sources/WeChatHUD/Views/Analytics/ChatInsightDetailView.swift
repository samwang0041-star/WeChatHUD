import SwiftUI

/// Detail view for a single chat's insight analysis.
struct ChatInsightDetailView: View {
    let chatUsername: String
    let chatName: String
    let result: ChatInsightResult

    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(chatName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Text(result.overallMood)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Topics
                    detailSection("在聊什么") {
                        ForEach(Array(result.topics.enumerated()), id: \.offset) { _, topic in
                            topicRow(topic)
                        }
                    }

                    // Waiting for me
                    if !result.waitingForMe.isEmpty || !result.myCommitments.isEmpty {
                        detailSection("和我相关") {
                            if result.mentionsMe > 0 {
                                detailBullet("被@\(result.mentionsMe)次")
                            }
                            ForEach(Array(result.waitingForMe.enumerated()), id: \.offset) { _, item in
                                detailBullet("⚠ \(item.source)等你: \(item.what) (已等\(String(format: "%.0f", item.waitingHours))h)")
                            }
                            ForEach(Array(result.myCommitments.enumerated()), id: \.offset) { _, c in
                                detailBullet("📌 你承诺: \(c)")
                            }
                        }
                    }

                    // Mood
                    detailSection("氛围") {
                        HStack(spacing: 8) {
                            moodBadge(result.overallMood)
                            Text("信噪比 \(Int(result.signalNoiseRatio * 100))%")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.4))
                            Text("决策效率 \(result.decisionEfficiency)")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.4))
                        }

                        if let shift = result.moodShift {
                            Text("💫 \(shift.time): \(shift.from) → \(shift.to)")
                                .font(.system(size: 10))
                                .foregroundColor(.yellow.opacity(0.7))
                            Text("触发: \(shift.trigger)")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }

                    // Attitudes
                    if let attitudes = result.attitudes, !attitudes.isEmpty {
                        detailSection("态度信号") {
                            ForEach(Array(attitudes.enumerated()), id: \.offset) { _, att in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(att.person)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.white.opacity(0.7))
                                        Text("→ \(att.topic)")
                                            .font(.system(size: 9))
                                            .foregroundColor(.white.opacity(0.4))
                                        Spacer()
                                        attitudeBadge(att.attitude)
                                    }
                                    Text("\u{201C}\(att.evidence)\u{201D}")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.35))
                                        .italic()
                                }
                            }
                        }
                    }

                    // Participants (group) or Relationship (private)
                    if let participants = result.participants, !participants.isEmpty {
                        detailSection("谁在说话") {
                            ForEach(Array(participants.enumerated()), id: \.offset) { _, p in
                                HStack {
                                    Text(p.name)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.white.opacity(0.7))
                                    Text("\(p.messageCount)条")
                                        .font(.system(size: 9).monospacedDigit())
                                        .foregroundColor(.white.opacity(0.35))
                                    Text(p.role)
                                        .font(.system(size: 9))
                                        .foregroundColor(.blue.opacity(0.6))
                                    Spacer()
                                    Text(p.doing)
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.4))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }

                    // Dark signals
                    if let tones = result.toneChanges, !tones.isEmpty {
                        detailSection("🔇 暗信号") {
                            ForEach(Array(tones.enumerated()), id: \.offset) { _, tone in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(tone.person): \(tone.change)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange.opacity(0.7))
                                    Text(tone.interpretation)
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.35))
                                }
                            }
                        }
                    }

                    // Insight + Suggestion
                    detailSection("💡 洞察") {
                        Text(result.insight)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                    }

                    detailSection("🎯 建议") {
                        Text(result.suggestion)
                            .font(.system(size: 11))
                            .foregroundColor(.green.opacity(0.7))
                    }

                    Spacer().frame(height: 20)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.08))
    }

    // MARK: - Components

    private func topicRow(_ topic: TopicInsight) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(topic.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                Text("\(topic.messageCount)条 · \(topic.participantCount)人")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
                Spacer()
                statusBadge(topic.status)
            }
            Text(topic.summary)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(3)
            if let involvement = topic.myInvolvement {
                Text("你: \(involvement)")
                    .font(.system(size: 9))
                    .foregroundColor(.blue.opacity(0.6))
            }
            if let cross = topic.crossChats, !cross.isEmpty {
                Text("🔗 也在: \(cross.joined(separator: ", "))")
                    .font(.system(size: 9))
                    .foregroundColor(.purple.opacity(0.6))
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.03))
        .cornerRadius(4)
    }

    @ViewBuilder
    private func detailSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
            content()
        }
    }

    private func detailBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("•").foregroundColor(.white.opacity(0.3)).font(.system(size: 10))
            Text(text).font(.system(size: 10)).foregroundColor(.white.opacity(0.65))
        }
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(status == "已决" ? .green : status == "搁置" ? .gray : .yellow)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background((status == "已决" ? Color.green : status == "搁置" ? Color.gray : Color.yellow).opacity(0.12))
            .cornerRadius(3)
    }

    private func moodBadge(_ mood: String) -> some View {
        let color: Color = mood.contains("焦虑") || mood.contains("紧张") ? .red
            : mood.contains("轻松") ? .green : .white
        return Text(mood)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color.opacity(0.7))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .cornerRadius(4)
    }

    private func attitudeBadge(_ attitude: String) -> some View {
        let color: Color = attitude.contains("积极") ? .green
            : attitude.contains("反对") ? .red
            : attitude.contains("敷衍") ? .gray
            : .yellow
        return Text(attitude)
            .font(.system(size: 8))
            .foregroundColor(color.opacity(0.8))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color.opacity(0.1))
            .cornerRadius(2)
    }
}
