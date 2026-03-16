import SwiftUI

struct TerminalTabBar: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(store.openTabIDs, id: \.self) { sessionID in
                    if let session = store.session(for: sessionID) {
                        tabButton(session: session, isActive: store.activeTabID == sessionID)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func tabButton(session: SessionConfiguration, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.tabColor)
                .frame(width: 8, height: 8)

            Image(systemName: session.tabIconName)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(session.name)
                .font(.system(size: 12))
                .lineLimit(1)

            Button {
                store.closeTab(sessionID: session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isActive ? Color(nsColor: .selectedControlColor).opacity(0.3) : .clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle()
                    .fill(session.tabColor)
                    .frame(height: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            store.switchToTab(sessionID: session.id)
        }
    }
}
