import SwiftUI
import SidebarModel

/// Arc's Emoji / Icon picker, anchored below the item it changes. A pick
/// applies at once; dismissing the popover leaves the item alone.
struct ItemIconEditorView: View {
    let model: BrowserViewModel
    let itemID: UUID
    @State private var showsEmoji = true
    @State private var query = ""

    private static let emojis: [(String, String)] = [
        ("😀", "smile happy face"), ("😎", "cool sunglasses face"), ("🥰", "love face"), ("🤔", "thinking face"),
        ("🎉", "party celebration"), ("❤️", "heart love"), ("⭐️", "star"), ("🔥", "fire"),
        ("🌈", "rainbow"), ("☀️", "sun weather"), ("🌙", "moon night"), ("🌍", "earth world travel"),
        ("🌱", "plant seedling"), ("🌸", "flower blossom"), ("🌴", "palm tree"), ("🍀", "clover luck"),
        ("🐶", "dog animal"), ("🐱", "cat animal"), ("🦊", "fox animal"), ("🐻", "bear animal"),
        ("🍎", "apple food"), ("🍋", "lemon food"), ("☕️", "coffee drink"), ("🍕", "pizza food"),
        ("🏠", "home house"), ("🏖️", "beach holiday"), ("✈️", "plane travel"), ("🚀", "rocket space"),
        ("🎨", "art palette design"), ("🎵", "music note"), ("🎮", "game controller"), ("📷", "camera photo"),
        ("📚", "books study"), ("💻", "computer work"), ("💡", "idea light"), ("🛠️", "tools build"),
        ("✅", "check done"), ("📌", "pin"), ("💎", "diamond"), ("🎯", "target goal"),
    ]
    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8)

    static func emojiChoices(matching query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = emojis.filter { needle.isEmpty || $0.0.contains(needle) || $0.1.localizedCaseInsensitiveContains(needle) }.map(\.0)
        if needle.count == 1, !matches.contains(needle),
           needle.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x7F }) {
            return [needle] + matches
        }
        return matches
    }

    static func symbolChoices(matching query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = Space.iconChoices.filter { needle.isEmpty || $0.localizedCaseInsensitiveContains(needle) }
        if !needle.isEmpty, !matches.contains(needle), NSImage(systemSymbolName: needle, accessibilityDescription: nil) != nil {
            return [needle] + matches
        }
        return matches
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("Icon type", selection: $showsEmoji) {
                Text("Emoji").tag(true)
                Text("Icon").tag(false)
            }
            .pickerStyle(.segmented)
            TextField("Search…", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    if showsEmoji {
                        ForEach(Self.emojiChoices(matching: query), id: \.self) { emoji in
                            choice(.emoji(emoji)) { Text(emoji).font(.system(size: 22)) }
                        }
                    } else {
                        ForEach(Self.symbolChoices(matching: query), id: \.self) { name in
                            choice(.sfSymbol(name: name)) { Image(systemName: name).font(.system(size: 17)) }
                        }
                    }
                }
            }
            .frame(height: 180)
            HStack {
                Button { apply(nil) } label: { Image(systemName: "trash") }
                    .help("Remove Icon").accessibilityLabel("Remove Icon")
                Spacer()
                if showsEmoji {
                    Button("Emoji & Symbols…") { NSApp.orderFrontCharacterPalette(nil) }
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 306)
        .onExitCommand { model.itemIconEditorID = nil }
    }

    private func choice<Label: View>(_ icon: SidebarItemIcon, @ViewBuilder label: () -> Label) -> some View {
        Button { apply(icon) } label: {
            label().frame(width: 30, height: 30)
                .background(model.store.customIcon(for: itemID) == icon ? Color.accentColor.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private func apply(_ icon: SidebarItemIcon?) {
        model.store.setCustomIcon(icon, for: itemID)
        model.itemIconEditorID = nil
    }
}

struct ItemIconPopover: ViewModifier {
    let model: BrowserViewModel
    let itemID: UUID

    func body(content: Content) -> some View {
        content.popover(isPresented: Binding(
            get: { model.itemIconEditorID == itemID },
            set: { if !$0, model.itemIconEditorID == itemID { model.itemIconEditorID = nil } }
        ), arrowEdge: .top) {
            ItemIconEditorView(model: model, itemID: itemID)
        }
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
