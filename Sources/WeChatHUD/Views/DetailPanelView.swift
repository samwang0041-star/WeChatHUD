import SwiftUI

/// Detail panel = SettingsView directly. The earlier "chat list" landing
/// page was removed — the gear button jumps straight here.
struct DetailPanelView: View {
    @EnvironmentObject var panelState: PanelState

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SettingsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Explicit close — back to compact pill.
            Button(action: { panelState.collapse() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }
}
