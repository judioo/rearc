import SwiftUI
import SidebarModel

struct EaselRowView: View {
    let ref: SidebarEaselRef
    let title: String
    var isNote = false
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var draftTitle = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isNote ? "note.text" : "paintpalette")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            if isEditing {
                TextField("Easel title", text: $draftTitle, onCommit: commitRename)
                    .textFieldStyle(.plain)
            } else {
                Text(title)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            draftTitle = title
            isEditing = true
        }
        .onTapGesture { onSelect() }
    }

    private func commitRename() {
        isEditing = false
        onRename(draftTitle)
    }
}
