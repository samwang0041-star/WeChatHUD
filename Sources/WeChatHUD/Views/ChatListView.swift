import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Filter tabs
            HStack(spacing: 8) {
                Text("全部")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(4)

                ForEach(WhitelistCategory.allCases, id: \.self) { cat in
                    Text(cat.label)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().background(Color.white.opacity(0.1))

            // Chat list (placeholder for Phase 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sectionHeader("@提到你", count: monitor.stats.atMentionCount)
                    sectionHeader("需回复", count: monitor.stats.importantCount)
                    sectionHeader("最近活跃", count: monitor.stats.unreadCount)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            Spacer()

            Divider().background(Color.white.opacity(0.1))

            // Bottom toolbar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                Text("搜索...")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            if count > 0 {
                Text("(\(count))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
