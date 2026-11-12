import AppKit
import SwiftUI
import SidebarModel

/// Create a Space as a page of the sidebar, after the profile's last space,
/// as Arc lays it out (docs/arc-recordings/2026-11-06-space-swipe-feel-and-new-space.md
/// §2.4): three cards, the title and subtitle, the name field with a leading
/// icon button, the Profile row, Choose a Theme (the editor popover, over
/// the page), then a full-width Create Space button in the theme's colour
/// with Cancel under it. The window takes the draft's theme as it is edited.
/// Nothing is created until Create; Cancel, Escape or a swipe back onto a
/// space leaves the sidebar as it was.
struct SpaceCreationPage: View {
    let model: BrowserViewModel
    @Environment(\.themeChrome) private var chrome
    @FocusState private var nameFocused: Bool
    @State private var emoji = ""
    @State private var choosingIcon = false
    @State private var pageWindow = WeakWindow()

    /// While the page fades out after Cancel the session is gone; it keeps
    /// drawing the last draft instead of changing under the fade.
    @State private var shown: SpaceDraft?

    private var draft: Binding<SpaceDraft> {
        Binding(
            get: { model.spaceCreation?.draft ?? shown ?? SpaceDraft.blank(in: model.store) },
            set: { model.spaceCreation?.draft = $0 }
        )
    }

    var body: some View {
        let current = draft.wrappedValue
        VStack(spacing: 0) {
            SpaceCreationCards()
                .padding(.top, 30)
            Text("Create a Space")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(chrome.title)
                .padding(.top, 14)
            Text("Separate your tabs for life, work, projects, and more.")
                .font(.system(size: 12.5))
                .foregroundStyle(chrome.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 10)

            VStack(spacing: 8) {
                nameField(current)
                profileRow(current)
                ChooseThemeRow(theme: draft.theme, arrowEdge: .trailing, height: 34)
            }
            .padding(.top, 26)

            Spacer(minLength: 16)

            Button(action: create) {
                Text("Create Space")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(createColor(current), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(current.canCreate(in: model.store) ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!current.canCreate(in: model.store))
            Button("Cancel") { model.cancelSpaceCreation() }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(chrome.secondaryText)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 12)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(PageWindowReader { window in
            pageWindow.window = window
            focusNameField(in: window)
        })
        // Esc in the focused name field, as well as Cancel's shortcut.
        .onExitCommand { model.cancelSpaceCreation() }
        .onAppear { shown = model.spaceCreation?.draft }
        .onChange(of: model.spaceCreation?.draft) { _, value in
            if let value { shown = value }
        }
        // New Space again while the page still fades out after Cancel.
        .onChange(of: model.spaceCreation == nil) { _, closed in
            if !closed, let window = pageWindow.window { focusNameField(in: window) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Create a Space")
    }

    private func nameField(_ current: SpaceDraft) -> some View {
        HStack(spacing: 8) {
            Button { choosingIcon = true } label: {
                Group {
                    if current.iconName.isEmpty {
                        Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                    } else {
                        SpaceIconView(iconName: current.iconName, size: 11)
                    }
                }
                .foregroundStyle(chrome.secondaryText)
                .frame(width: 18, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(chrome.secondaryText.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: current.iconName.isEmpty ? [2, 2] : []))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose an icon")
            .accessibilityLabel("Choose an icon")
            .popover(isPresented: $choosingIcon, arrowEdge: .trailing) { iconPicker }
            TextField(Self.namePlaceholder, text: draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($nameFocused)
                .onSubmit(create)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(chrome.separator, lineWidth: 1))
    }

    static let namePlaceholder = "Space name…"

    /// The name field takes the keyboard as the page opens, from the + menu,
    /// the overscroll and the command bar. Focus asked of SwiftUI on appear
    /// didn't hold: the command bar, closing, handed the keyboard back to the
    /// page (`restorePageFocus` now leaves it), and a focused page keeps it
    /// over SwiftUI's request. So, as the command bar does
    /// (`focusFieldInFirstFrame`), the page lets go and the field takes the
    /// keyboard over AppKit once the page is in its window, and takes it
    /// again while the fade runs if the page or nothing has it. It never
    /// takes it from another field.
    private func focusNameField(in window: NSWindow, attempts: Int = 12) {
        if ShortcutRouter.isWebContent(window.firstResponder) { window.makeFirstResponder(nil) }
        DispatchQueue.main.async {
            guard model.spaceCreation != nil else { return }
            if let field = CommandBarOverlay.field(in: window, placeholder: Self.namePlaceholder) {
                if field.currentEditor() == nil { window.makeFirstResponder(field) }
            } else {
                nameFocused = true
            }
            reclaimNameFocus(in: window, attempts: attempts)
        }
    }

    private func reclaimNameFocus(in window: NSWindow, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            guard attempts > 0, model.spaceCreation != nil, window.isKeyWindow,
                  let field = CommandBarOverlay.field(in: window, placeholder: Self.namePlaceholder) else { return }
            let responder = window.firstResponder
            if field.currentEditor() == nil, responder == nil || responder === window || ShortcutRouter.isWebContent(responder) {
                window.makeFirstResponder(field)
            }
            reclaimNameFocus(in: window, attempts: attempts - 1)
        }
    }

    private func profileRow(_ current: SpaceDraft) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "face.smiling")
                .font(.system(size: 12))
                .foregroundStyle(chrome.secondaryText)
            Text("Profile").font(.system(size: 13, weight: .medium))
            Spacer(minLength: 4)
            // The profile, and whether the space gets its own container inside it.
            Menu {
                ForEach(model.store.listedProfiles) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { current.profileID == profile.id },
                        set: { if $0 { draft.wrappedValue.profileID = profile.id } }
                    ))
                }
                Divider()
                Toggle("Its Own Container", isOn: Binding(
                    get: { current.createsOwnContainer },
                    set: { draft.wrappedValue.createsOwnContainer = $0 }
                ))
                .help(ContainerChip.help)
            } label: {
                let name = model.store.profile(withID: current.profileID)?.name ?? "Profile"
                Text(current.createsOwnContainer ? "\(name) · Container" : name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.accessoryBar)
            .fixedSize()
            .frame(maxWidth: 120, alignment: .trailing)
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(chrome.secondaryText)
                .help(current.createsOwnContainer
                      ? "The space is in this profile, with its own container: its own cookies, sign-ins and site data"
                      : "The space's tabs use this profile's cookies, history and favorites")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var fieldFill: Color {
        chrome.isWindowDark ? Color.white.opacity(0.08) : Color.white.opacity(0.6)
    }

    /// The theme's accent, as Arc tints the button (red on a red theme).
    private func createColor(_ draft: SpaceDraft) -> Color {
        Color(SpaceThemeRoles(theme: draft.theme).semantic(dark: chrome.isWindowDark).foregroundPrimary)
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 6), spacing: 6) {
                ForEach(Space.iconChoices, id: \.self) { symbol in
                    Button {
                        draft.wrappedValue.iconName = symbol
                        choosingIcon = false
                    } label: {
                        Image(systemName: symbol)
                            .frame(width: 30, height: 30)
                            .background(
                                draft.wrappedValue.iconName == symbol ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(symbol)
                }
            }
            HStack {
                TextField("Or type an emoji", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit(useEmoji)
                Button("Use") { useEmoji() }
                    .disabled(emoji.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button("Emoji & Symbols…") { NSApp.orderFrontCharacterPalette(nil) }
        }
        .padding(12)
    }

    private func create() {
        guard let session = model.spaceCreation else { return }
        model.createSpace(from: session.draft)
    }

    /// Lowercase words would be read as an SF Symbol name; take them only if one exists.
    private func useEmoji() {
        let glyph = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !glyph.isEmpty else { return }
        if Space.isSymbolName(glyph), NSImage(systemSymbolName: glyph, accessibilityDescription: nil) == nil { return }
        draft.wrappedValue.iconName = Space.isSymbolName(glyph) ? glyph : String(glyph.prefix(2))
        choosingIcon = false
    }
}

/// The window the page is in, kept for New Space again during the fade.
private final class WeakWindow {
    weak var window: NSWindow?
}

/// Calls back once the page is in a window.
private struct PageWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Arc's three fanned cards over the title.
private struct SpaceCreationCards: View {
    var body: some View {
        ZStack {
            card("leaf.fill", tint: .green).rotationEffect(.degrees(-12)).offset(x: -17, y: 3)
            card("book.closed.fill", tint: .orange).rotationEffect(.degrees(12)).offset(x: 17, y: 3)
            card("laptopcomputer", tint: .gray)
        }
        .frame(width: 72, height: 44)
        .accessibilityHidden(true)
    }

    private func card(_ symbol: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.white)
            .frame(width: 26, height: 34)
            .overlay(Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}
