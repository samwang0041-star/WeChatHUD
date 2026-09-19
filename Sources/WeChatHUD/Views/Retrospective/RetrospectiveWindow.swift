import SwiftUI

/// Independent retrospective window. Reuses the same live surface as the
/// floating tab, but gives it enough room to be useful as a standalone
/// workspace.
struct RetrospectiveWindow: View {
    @EnvironmentObject var monitor: ChatMonitor

    /// This window is its own root: the island and the workspace publish the
    /// display-options generation, but neither is an ancestor of this view, so
    /// a live switch flip stopped at the border until it did too.
    @State private var displayOptionsGeneration = CompanionAccessibility.generation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(CompanionProductCopy.timeReview)
                    .workspaceTitle()
                    .companionDimmedForeground(0.92)
                Spacer()
                Text(CompanionProductCopy.brandName)
                    .font(.system(size: 11, weight: .medium))
                    .companionDimmedForeground(0.35)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Divider().overlay(Color.white.opacity(CompanionAccessibility.contrastAdjusted(0.08)))

            RetrospectiveTabView()
                .environmentObject(monitor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.96))
        .companionDisplayGeneration(displayOptionsGeneration)
        .onReceive(NotificationCenter.default.publisher(for: CompanionAccessibility.displayOptionsDidChange)) { _ in
            displayOptionsGeneration &+= 1
        }
    }
}
