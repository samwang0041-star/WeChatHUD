import SwiftUI

/// A row showing a recalled (撤回) message with optional AI analysis.
/// Clicking the row expands it to reveal `aiDetail`.
struct RecalledMessageRow: View {
    let recalled: RecalledMessage

    @State private var expanded = false
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if expanded, let detail = recalled.aiDetail, !detail.isEmpty {
                detailPanel(detail)
            }
        }
    }

    // MARK: - Main row

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 8) {
            // Left accent bar
            Rectangle()
                .fill(accentColor.opacity(0.8))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 4) {
                // Header line
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(accentColor)

                    Text("\(recalled.senderName) 撤回了一条消息")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(relativeTime(Date(timeIntervalSince1970: Double(recalled.recalledAt))))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                        .monospacedDigit()
                }

                // Original text
                if !recalled.originalText.isEmpty {
                    Text(recalled.originalText)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(expanded ? nil : 2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: expanded)
                }

                // Intelligence badge + AI reason
                HStack(spacing: 6) {
                    if let value = recalled.aiIntelligenceValue {
                        intelligenceBadge(value)
                    }
                    if let reason = recalled.aiReason, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    if recalled.aiDetail != nil {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
        }
        .padding(.leading, 0)   // accent bar provides left edge
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(hovered ? Color.white.opacity(0.06) : Color.clear)
        .overlay(
            Rectangle()
                .fill(accentColor.opacity(0.8))
                .frame(width: 2),
            alignment: .leading
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                expanded.toggle()
            }
        }
    }

    // MARK: - Detail panel

    private func detailPanel(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .background(Color.white.opacity(0.06))
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .padding(.leading, 22)
                .padding(.trailing, 12)
                .padding(.vertical, 6)
        }
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Intelligence badge

    private func intelligenceBadge(_ value: String) -> some View {
        let (label, color) = badgeStyle(value)
        return Text(label)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(3)
    }

    private func badgeStyle(_ value: String) -> (String, Color) {
        switch value.lowercased() {
        case "high":   return ("情报:高", .red)
        case "medium": return ("情报:中", .orange)
        default:       return ("情报:低", .white.opacity(0.4))
        }
    }

    // MARK: - Accent color

    private var accentColor: Color {
        switch recalled.aiIntelligenceValue?.lowercased() {
        case "high":   return .red
        case "medium": return .orange
        default:       return .white.opacity(0.25)
        }
    }

    // MARK: - Relative time

    private func relativeTime(_ date: Date) -> String {
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(diff / 60)分前" }
        if diff < 86400 { return "\(diff / 3600)时前" }
        return "\(diff / 86400)天前"
    }
}
