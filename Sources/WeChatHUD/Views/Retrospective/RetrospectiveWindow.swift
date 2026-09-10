import SwiftUI

/// Independent retrospective window. Reuses the same live surface as the
/// floating tab, but gives it enough room to be useful as a standalone
/// workspace.
struct RetrospectiveWindow: View {
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(CompanionProductCopy.timeReview)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                Spacer()
                Text(CompanionProductCopy.brandName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Divider().overlay(Color.white.opacity(0.08))

            RetrospectiveTabView()
                .environmentObject(monitor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.96))
    }
}
