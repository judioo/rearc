import SidebarModel
import SwiftUI

/// Arc-style floating find bar at the page's top-trailing corner: query
/// field, "n of m", previous/next, match case, close. The field turns red
/// when nothing matches.
struct FindBarView: View {
    let find: FindBarModel

    @FocusState private var fieldFocused: Bool
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Find on page", text: Binding(get: { find.query }, set: { find.setQuery($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(minWidth: 150, idealWidth: 190, maxWidth: 230)
                .focused($fieldFocused)
                .onSubmit { find.next(forward: !NSEvent.modifierFlags.contains(.shift)) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    find.next(forward: false)
                    return .handled
                }
            Text(find.statusText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(find.hasNoMatches ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: find.statusText)
            Divider().frame(height: 16)
            iconButton("chevron.up", help: "Previous Match (⇧⌘G)") { find.next(forward: false) }
            iconButton("chevron.down", help: "Next Match (⌘G)") { find.next(forward: true) }
            Toggle(isOn: Binding(get: { find.state.matchCase }, set: { find.setMatchCase($0) })) {
                Text("Aa").font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Match Case")
            Button { find.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(hoveringClose ? 0.12 : 0)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .onHover { hoveringClose = $0 }
            .help("Close (Esc)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(find.hasNoMatches ? Color.red.opacity(0.55) : Color.primary.opacity(0.1))
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .padding(.top, 10)
        .padding(.trailing, 12)
        .onExitCommand { find.close() }
        .onAppear { fieldFocused = true }
        .onChange(of: find.focusToken) { _, _ in
            fieldFocused = true
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(find.query.isEmpty)
        .help(help)
    }
}

extension View {
    /// Overlays the find bar on a page view when the bar targets `engine`.
    func findBar(_ find: FindBarModel, for engine: (any WebEngine)?) -> some View {
        modifier(FindBarOverlay(find: find, engine: engine))
    }
}

private struct FindBarOverlay: ViewModifier {
    let find: FindBarModel
    let engine: (any WebEngine)?
    @Environment(\.addressBarOverlayInset) private var toolbarInset

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if find.isShown(for: engine) {
                FindBarView(find: find)
                    .padding(.top, toolbarInset)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.22, bounce: 0.15), value: find.isShown(for: engine))
    }
}
