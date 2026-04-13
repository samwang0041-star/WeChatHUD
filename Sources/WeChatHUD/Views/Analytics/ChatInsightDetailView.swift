import SwiftUI

/// Detail view for a single chat — macOS native style with card modules.
struct ChatInsightDetailView: View {
    let chatUsername: String
    let chatName: String
    let isGroup: Bool
    let category: WhitelistCategory
    let result: ChatInsightResult?
    @Binding var selectedDate: Date

    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if let result = result {
                analysisContent(result)
            } else {
                loadingState
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            // Back breadcrumb
            Button(action: {}) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10))
                    Text(chatName)
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.primary)
            }
            .buttonStyle(.plain)

            Text(dateLabel)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer()

            // Date picker
            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .frame(width: 120)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var dateLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日 EEEE"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt.string(from: selectedDate)
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(spacing: 12) {
            if monitor.insightLoading {
                ProgressView()
                    .controlSize(.regular)
                Text(monitor.insightProgress.isEmpty ? "正在分析..." : monitor.insightProgress)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                    .foregroundColor(.orange.opacity(0.4))
                Text("正在准备分析...")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Analysis content

    @ViewBuilder
    private func analysisContent(_ r: ChatInsightResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Row 1: Stats cards
                HStack(spacing: 12) {
                    statCard(
                        value: "\(r.topics.reduce(0) { $0 + $1.messageCount })",
                        label: "消息数",
                        icon: "bubble.left.and.bubble.right",
                        color: .blue
                    )
                    statCard(
                        value: "\(r.participants?.count ?? 1)",
                        label: "发言人数",
                        icon: "person.2",
                        color: .purple
                    )
                    if let top = r.participants?.first {
                        VStack(spacing: 4) {
                            Text(top.name)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.orange)
                            Text("最活跃 (\(top.messageCount)条)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(10)
                    }
                }

                // Row 2: Mood + Signal noise + Decision
                HStack(spacing: 12) {
                    moduleCard("群氛围", icon: "face.smiling") {
                        HStack(spacing: 8) {
                            moodIcon(r.overallMood)
                            Text(r.overallMood)
                                .font(.system(size: 14, weight: .medium))
                        }
                        if let shift = r.moodShift {
                            Text("\(shift.from) → \(shift.to)")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                            Text(shift.trigger)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }

                    moduleCard("信息质量", icon: "chart.bar") {
                        // Signal noise ratio as a visual bar
                        HStack(spacing: 8) {
                            signalBar(r.signalNoiseRatio)
                            Text("\(Int(r.signalNoiseRatio * 100))%")
                                .font(.system(size: 16, weight: .bold).monospacedDigit())
                                .foregroundColor(r.signalNoiseRatio > 0.6 ? .green : .orange)
                        }
                        Text("决策效率: \(r.decisionEfficiency)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    moduleCard("与我相关", icon: "at") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("@我").font(.system(size: 10)).foregroundColor(.secondary)
                                Spacer()
                                Text("\(r.mentionsMe)次").font(.system(size: 12, weight: .medium))
                            }
                            HStack {
                                Text("等回复").font(.system(size: 10)).foregroundColor(.secondary)
                                Spacer()
                                Text("\(r.waitingForMe.count)项")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(r.waitingForMe.isEmpty ? .primary : .red)
                            }
                            HStack {
                                Text("我的承诺").font(.system(size: 10)).foregroundColor(.secondary)
                                Spacer()
                                Text("\(r.myCommitments.count)项").font(.system(size: 12, weight: .medium))
                            }
                        }
                    }
                }

                // Row 3: Topics
                moduleCardFull("话题讨论", icon: "text.bubble") {
                    ForEach(Array(r.topics.enumerated()), id: \.offset) { _, topic in
                        topicCard(topic)
                    }
                }

                // Row 4: Attitudes
                if let attitudes = r.attitudes, !attitudes.isEmpty {
                    moduleCardFull("态度信号", icon: "person.crop.circle.badge.questionmark") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(Array(attitudes.enumerated()), id: \.offset) { _, att in
                                attitudeCard(att)
                            }
                        }
                    }
                }

                // Row 5: Participants (group)
                if let participants = r.participants, !participants.isEmpty {
                    moduleCardFull("成员参与度", icon: "person.3") {
                        ForEach(Array(participants.enumerated()), id: \.offset) { _, p in
                            participantRow(p, maxCount: participants.first?.messageCount ?? 1)
                        }
                    }
                }

                // Row 6: Dark signals
                if hasDarkSignals(r) {
                    moduleCardFull("暗信号", icon: "eye.slash") {
                        if let tones = r.toneChanges {
                            ForEach(Array(tones.enumerated()), id: \.offset) { _, t in
                                darkSignalRow(icon: "waveform", color: .orange,
                                            title: "\(t.person): \(t.change)",
                                            detail: t.interpretation)
                            }
                        }
                        if let ignored = r.ignoredNotes {
                            ForEach(Array(ignored.enumerated()), id: \.offset) { _, ig in
                                darkSignalRow(icon: "bubble.left.and.exclamationmark.bubble.right", color: .gray,
                                            title: "\(ig.person) 的消息被忽略",
                                            detail: ig.interpretation)
                            }
                        }
                    }
                }

                // Row 7: Insight + Suggestion
                HStack(spacing: 12) {
                    moduleCard("洞察", icon: "lightbulb") {
                        Text(r.insight)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                    }
                    moduleCard("行动建议", icon: "arrow.right.circle") {
                        Text(r.suggestion)
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    }
                }

                Spacer().frame(height: 20)
            }
            .padding(20)
        }
    }

    // MARK: - Components

    private func statCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 22, weight: .bold).monospacedDigit())
                .foregroundColor(.primary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func moduleCard(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func moduleCardFull(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    private func topicCard(_ topic: TopicInsight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(topic.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                statusBadge(topic.status)
            }
            HStack(spacing: 12) {
                Label("\(topic.messageCount)条", systemImage: "bubble.left")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Label("\(topic.participantCount)人", systemImage: "person.2")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Text(topic.summary)
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(3)
            if let involvement = topic.myInvolvement {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 9))
                        .foregroundColor(.blue)
                    Text("你: \(involvement)")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                }
            }
            if let cross = topic.crossChats, !cross.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                        .foregroundColor(.purple)
                    Text("也在: \(cross.joined(separator: ", "))")
                        .font(.system(size: 10))
                        .foregroundColor(.purple)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func attitudeCard(_ att: AttitudeSignal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(att.person)
                    .font(.system(size: 11, weight: .medium))
                attitudeBadge(att.attitude)
            }
            Text(att.topic)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text("「\(att.evidence)」")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
                .italic()
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(6)
    }

    private func participantRow(_ p: ParticipantRole, maxCount: Int) -> some View {
        HStack(spacing: 10) {
            // Avatar
            ZStack {
                Circle()
                    .fill(roleColor(p.role).opacity(0.15))
                    .frame(width: 28, height: 28)
                Text(String(p.name.prefix(1)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(roleColor(p.role))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(p.name)
                        .font(.system(size: 12, weight: .medium))
                    Text(p.role)
                        .font(.system(size: 9))
                        .foregroundColor(roleColor(p.role))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(roleColor(p.role).opacity(0.1))
                        .cornerRadius(3)
                }
                Text(p.doing)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Message count bar
            HStack(spacing: 4) {
                GeometryReader { geo in
                    let fraction = maxCount > 0 ? CGFloat(p.messageCount) / CGFloat(maxCount) : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(roleColor(p.role).opacity(0.3))
                        .frame(width: geo.size.width * fraction)
                }
                .frame(width: 60, height: 6)
                Text("\(p.messageCount)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func darkSignalRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.05))
        .cornerRadius(6)
    }

    // MARK: - Small helpers

    private func statusBadge(_ status: String) -> some View {
        let color: Color = status == "已决" ? .green : status == "搁置" ? .gray : .orange
        return Text(status)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .cornerRadius(4)
    }

    private func attitudeBadge(_ attitude: String) -> some View {
        let color: Color = attitude.contains("积极") ? .green
            : attitude.contains("反对") ? .red
            : attitude.contains("敷衍") ? .gray
            : .orange
        return Text(attitude)
            .font(.system(size: 9))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.1))
            .cornerRadius(3)
    }

    private func moodIcon(_ mood: String) -> some View {
        let (icon, color): (String, Color) = {
            if mood.contains("焦虑") || mood.contains("紧张") { return ("exclamationmark.triangle", .red) }
            if mood.contains("轻松") { return ("face.smiling", .green) }
            if mood.contains("正式") { return ("briefcase", .blue) }
            return ("minus.circle", .secondary)
        }()
        return Image(systemName: icon)
            .font(.system(size: 16))
            .foregroundColor(color)
    }

    private func signalBar(_ ratio: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 3)
                    .fill(ratio > 0.6 ? Color.green : Color.orange)
                    .frame(width: geo.size.width * ratio)
            }
        }
        .frame(width: 80, height: 8)
    }

    private func roleColor(_ role: String) -> Color {
        if role.contains("推动") { return .blue }
        if role.contains("决策") { return .purple }
        if role.contains("执行") { return .green }
        if role.contains("反对") { return .red }
        return .gray
    }

    private func hasDarkSignals(_ r: ChatInsightResult) -> Bool {
        let hasTones = !(r.toneChanges ?? []).isEmpty
        let hasIgnored = !(r.ignoredNotes ?? []).isEmpty
        let hasRecalls = !(r.recalledNotes ?? []).isEmpty
        return hasTones || hasIgnored || hasRecalls
    }
}
