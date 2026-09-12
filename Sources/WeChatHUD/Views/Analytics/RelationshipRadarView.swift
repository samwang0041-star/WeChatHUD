import SwiftUI

/// Stub surface for 关系雷达. The model/store/service are live; this view
/// only lists persisted snapshots so the insight dashboard can grow a
/// dedicated pane without waiting on a full visual design.
struct RelationshipRadarView: View {
    let snapshots: [RelationshipRadarSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                Text("关系雷达")
                    .font(.headline)
                Spacer()
                Text("跨天趋势")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if snapshots.isEmpty {
                Text("还没有跨天趋势。单聊分析会先积累 topics / decisions，雷达再判断态度和沉默。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(snapshots, id: \.chatUsername) { snap in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snap.relationshipTrend)
                            .font(.subheadline.weight(.semibold))
                        Text(snap.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("关系雷达")
    }
}
