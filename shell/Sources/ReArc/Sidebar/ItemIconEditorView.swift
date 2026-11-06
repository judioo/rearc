import SwiftUI
import SidebarModel

struct ItemIconEditorView: View {
    let model: BrowserViewModel
    let itemID: UUID
    @State private var icon: SidebarItemIcon = .sfSymbol(name: "star.fill")
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Icon").font(.headline)
            SidebarGlyphView(icon: icon, fallback: "star.fill", size: 28)
                .frame(maxWidth: .infinity)
            IconChooser(selection: $icon)
            HStack {
                Button("Reset Icon") {
                    model.store.setCustomIcon(nil, for: itemID)
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.store.setCustomIcon(icon, for: itemID)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { icon = model.store.customIcon(for: itemID) ?? icon }
    }
}

struct ItemIconMenu: View {
    let model: BrowserViewModel
    let itemID: UUID

    var body: some View {
        Button("Change Icon…") { model.itemIconEditorID = itemID }
        Button("Reset Icon") { model.store.setCustomIcon(nil, for: itemID) }
            .disabled(model.store.customIcon(for: itemID) == nil)
    }
}
