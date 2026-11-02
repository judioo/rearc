import SwiftUI
import SidebarModel

/// Minimal standalone window: slim header + single web view (no sidebar).
struct LittleArcWindowView: View {
    @Bindable var model: BrowserViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    let windowID: LittleArcWindow.ID

    private var record: LittleArcWindow? {
        model.store.littleArcWindow(withID: windowID)
    }

    var body: some View {
        Group {
            if let record {
                VStack(spacing: 0) {
                    header(for: record)
                    Divider()
                    model.littleArcEngine(for: windowID)
                        .makeView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("Little Arc window unavailable")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .onAppear {
            model.focusedLittleArcID = windowID
            model.touchLittleArcIfNeeded(windowID)
            model.loadLittleArcIfNeeded(windowID)
        }
        .onDisappear {
            if model.focusedLittleArcID == windowID {
                model.focusedLittleArcID = nil
            }
            if model.store.littleArcWindow(withID: windowID) != nil {
                model.closeLittleArcWindow(windowID)
            }
        }
    }

    private func header(for record: LittleArcWindow) -> some View {
        HStack(spacing: 10) {
            Text(record.title)
                .font(.headline)
                .lineLimit(1)
            Text(record.url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Promote") {
                model.promoteLittleArcWindow(windowID)
                dismissWindow(id: "littleArc", value: windowID)
            }
            Button {
                model.closeLittleArcWindow(windowID)
                dismissWindow(id: "littleArc", value: windowID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
