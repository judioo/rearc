import SwiftUI
import SidebarModel

/// The centered floating URL/search panel (Cmd+T / Cmd+L). Enter submits,
/// Escape dismisses, arrow keys move through live results. Typing a site's
/// name offers "Tab to search" it; Tab turns it into a pill and Delete on
/// an empty query removes it again (Arc site search, COMMAND-BAR §4.2).
/// Rows offer Copy URL and, for history, Remove from History on hover or
/// highlight and in their context menu; Shift+Delete removes the
/// highlighted history row (COMMAND-BAR §6.4). A typed domain completes
/// inline in grey (Right Arrow takes it), and ⌘↩ / ⌥↩ / ⇧↩ open a page
/// result in a new tab, a split or Little Arc (COMMAND-BAR §3, §6.3).
struct CommandBarOverlay: View {
    @Environment(\.themeChrome) private var themeChrome
    @Binding var text: String
    /// The inline completion's grey remainder after the typed text.
    var inlineSuffix: String?
    /// Right Arrow: returns true when it took the completion.
    var onAcceptCompletion: () -> Bool = { false }
    /// Return with a routing modifier.
    var onSubmitRoute: (CommandBarRoute) -> Void = { _ in }
    let results: [CommandBarSearch.Result]
    let highlightedIndex: Int
    var errorMessage: String?
    var siteSearch: SiteSearchEngine?
    var siteSearchSuggestion: SiteSearchEngine?
    /// Tab: returns true when it entered a site search.
    var onTab: () -> Bool = { false }
    /// Delete on an empty field: returns true when it removed the pill.
    var onDeleteBackward: () -> Bool = { false }
    /// Shift+Delete: returns true when it removed the highlighted history row.
    var onDeleteHighlighted: () -> Bool = { false }
    var onRowAction: (CommandBarRowAction, CommandBarSearch.Result) -> Void = { _, _ in }
    let onMoveHighlight: (Int) -> Void
    /// A click on a row, by its result's ID (rows that did not change keep
    /// their closures, so an index could be stale).
    let onSelectResult: (CommandBarSearch.Result.ID) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    /// Bumped when the field must take focus again (after ⌘T swaps the page
    /// that had it out from under the bar).
    var focusRequest = 0
    /// Arc's bar is ≈ 765 pt wide (ARC-RECORDING-ANALYSIS.md §8).
    var width: CGFloat = CommandBarOverlay.arcWidth
    /// The space a switch-to-tab row's tab lives in.
    var spaceName: (Space.ID) -> String? = { _ in nil }

    static let arcWidth: CGFloat = 765
    static let rowHeight: CGFloat = 43
    static let rowSpacing: CGFloat = 6
    /// The bar's top sits 38 % of the way down the window.
    static let topFraction: CGFloat = 0.38

    private var isCommandMode: Bool { text.hasPrefix(">") }

    @FocusState private var isFieldFocused: Bool
    @State private var earlyKeys = EarlyKeyCatcher()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                if let siteSearch {
                    SiteSearchPill(engine: siteSearch)
                        .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
                }
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    // Not a credential: AppKit then skips its password AutoFill
                    // check as the field takes the keyboard (≈ 3 ms on ⌘T / ⌘L).
                    .textContentType(.URL)
                    .focused($isFieldFocused)
                    .overlay(alignment: .leading) { inlineCompletion }
                    .onSubmit(onSubmit)
                    .onKeyPress(.return, phases: .down) { press in
                        let route = CommandBarRoute(
                            command: press.modifiers.contains(.command),
                            option: press.modifiers.contains(.option),
                            shift: press.modifiers.contains(.shift)
                        )
                        guard route != .current else { return .ignored }
                        onSubmitRoute(route)
                        return .handled
                    }
                    .onKeyPress(.rightArrow, phases: .down) { press in
                        press.modifiers.isEmpty && onAcceptCompletion() ? .handled : .ignored
                    }
                    .onKeyPress(.tab) { onTab() ? .handled : .ignored }
                    .onKeyPress(.delete) {
                        if NSEvent.modifierFlags.contains(.shift), onDeleteHighlighted() { return .handled }
                        return text.isEmpty && onDeleteBackward() ? .handled : .ignored
                    }
                if let siteSearchSuggestion {
                    TabToSearchHint(engine: siteSearchSuggestion)
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: siteSearch)
            .animation(.easeOut(duration: 0.12), value: siteSearchSuggestion)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if !results.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                        // Rows keep their slot, so a keystroke or an engine
                        // answer updates the visible rows in place instead of
                        // building new ones (5.5 → 2.3 ms for 12 changed rows),
                        // and equal rows skip their body. Hover stays with the
                        // row under the pointer.
                        let selection = selectionColor
                        ForEach(results.indices, id: \.self) { index in
                            let result = results[index]
                            CommandBarResultRow(
                                result: result,
                                isHighlighted: index == highlightedIndex,
                                selection: selection,
                                spaceName: result.kind == .openTab ? result.spaceID.flatMap(spaceName) : nil,
                                onAction: { onRowAction($0, result) },
                                onSelect: { onSelectResult(result.id) }
                            )
                            .equatable()
                        }
                    }
                }
                .padding(.vertical, 6)
                // As tall as its rows, up to about six (Arc's rows sit on a ≈ 49 pt pitch).
                .frame(height: min(CGFloat(results.count) * (Self.rowHeight + Self.rowSpacing) + 12, 6 * (Self.rowHeight + Self.rowSpacing)))
                if showsRouteHints {
                    Divider()
                    HStack(spacing: 14) {
                        ForEach(CommandBarRoute.allCases, id: \.self) { route in
                            Text(route.hint)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(width: width)
        // A neutral frosted panel, not the space's palette: only the selected
        // row takes the theme (ARC-RECORDING-ANALYSIS.md §8). A site search
        // tints the whole panel with the site's colour (frame 3034).
        .background(siteSearch.map { Color($0.color).opacity(0.22) } ?? Color.white.opacity(themeChrome.isWindowDark ? 0 : 0.3),
                    in: RoundedRectangle(cornerRadius: 14))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear {
            focusFieldInFirstFrame()
            earlyKeys.start(text: $text)
            reclaimFocusFromPage()
        }
        .onDisappear { earlyKeys.stop() }
        .onChange(of: focusRequest) { _, _ in
            isFieldFocused = false
            DispatchQueue.main.async { isFieldFocused = true }
        }
        .onExitCommand(perform: onCancel)
        .onKeyPress(.upArrow) {
            onMoveHighlight(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            onMoveHighlight(1)
            return .handled
        }
    }

    /// The field takes the keyboard before the bar's first frame is committed.
    /// On appear the field is not in the window yet: focus asked of SwiftUI
    /// then lands a frame or two late, and over a focused page SwiftUI first
    /// hands the keyboard back to the page, which costs the first frame
    /// another few milliseconds. So the page lets go here, and the field takes
    /// the keyboard over AppKit once this update has put it in the window.
    private func focusFieldInFirstFrame() {
        guard let window = NSApp.keyWindow else {
            isFieldFocused = true
            return
        }
        if ShortcutRouter.isWebContent(window.firstResponder) { window.makeFirstResponder(nil) }
        let placeholder = placeholder
        DispatchQueue.main.async {
            if let field = Self.field(in: window, placeholder: placeholder),
               field.currentEditor() != nil || window.makeFirstResponder(field) { return }
            isFieldFocused = true
        }
    }

    /// The bar's text field: the window's visible editable field with its placeholder.
    static func field(in window: NSWindow, placeholder: String) -> NSTextField? {
        func search(_ view: NSView) -> NSTextField? {
            if view.isHidden { return nil }
            if let field = view as? NSTextField, field.isEditable, field.placeholderString == placeholder { return field }
            for subview in view.subviews.reversed() {
                if let field = search(subview) { return field }
            }
            return nil
        }
        return window.contentView.flatMap(search)
    }

    /// On appear the field can be outside the window still, and a focused page
    /// (⌘L, ⌘T over web content) then keeps the keyboard: ask again while the
    /// page holds it. It never runs while the field has the keyboard, so typing
    /// in the field is never interrupted.
    private func reclaimFocusFromPage(attempts: Int = 5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard attempts > 0, ShortcutRouter.isWebContent(NSApp.keyWindow?.firstResponder) else { return }
            isFieldFocused = false
            DispatchQueue.main.async { isFieldFocused = true }
            reclaimFocusFromPage(attempts: attempts - 1)
        }
    }

    /// Keys typed straight after ⌘T or ⌘L, before the field has the keyboard,
    /// would reach the focused page or nothing: they go into the field instead. The
    /// prefilled URL is selected, so the first key replaces it, as in the field.
    @MainActor
    final class EarlyKeyCatcher {
        private var monitor: Any?
        private var caught = false

        func start(text: Binding<String>) {
            stop()
            caught = false
            var replaces = !text.wrappedValue.isEmpty
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Until a text field has the keyboard (the page, then the
                // window while focus moves), keys belong to the bar.
                if let field = event.window?.firstResponder as? NSTextView {
                    // Focus selects the whole field: keep what was caught.
                    if self?.caught == true { field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0)) }
                    self?.stop()
                    return event
                }
                let modifiers = event.modifierFlags.intersection([.command, .control, .option])
                guard modifiers.isEmpty, let characters = event.characters, !characters.isEmpty,
                      characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
                else { return event }
                text.wrappedValue = (replaces ? "" : text.wrappedValue) + characters
                replaces = false
                self?.caught = true
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    /// The selected row's fill: the theme accent lightened (`#858AFF` from
    /// `#2731FF` on Imara), or the site's colour during a site search.
    private var selectionColor: Color {
        siteSearch.map { Color($0.color) } ?? themeChrome.selection
    }

    /// The typed text, invisible, then the completion's remainder in grey.
    @ViewBuilder
    private var inlineCompletion: some View {
        if let inlineSuffix, !inlineSuffix.isEmpty {
            (Text(text).foregroundColor(.clear) + Text(inlineSuffix).foregroundColor(.secondary.opacity(0.7)))
                .font(.title3)
                .lineLimit(1)
                .allowsHitTesting(false)
                .accessibilityLabel("Completes to \(text + inlineSuffix)")
        }
    }

    /// Routing applies to pages, not commands.
    private var showsRouteHints: Bool {
        guard results.indices.contains(highlightedIndex) else { return false }
        return results[highlightedIndex].kind != .command
    }

    private var placeholder: String {
        if let siteSearch { return "Search \(siteSearch.name)" }
        return isCommandMode ? "Type a command…" : "Search or Enter URL…"
    }
}

/// One result on one line: icon, title, then "— subtitle" in grey; a
/// switch-to-tab row ends with its space's name and a → chip (§8). The
/// selected row is a rounded fill in the theme accent with white text. Row
/// actions show while hovered or selected. Equal rows skip their body: the
/// closures route through the model with this row's result, so a kept
/// closure acts the same.
struct CommandBarResultRow: View, Equatable {
    let result: CommandBarSearch.Result
    let isHighlighted: Bool
    let selection: Color
    var spaceName: String?
    let onAction: (CommandBarRowAction) -> Void
    let onSelect: () -> Void
    @State private var isHovering = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.result == rhs.result && lhs.isHighlighted == rhs.isHighlighted
            && lhs.selection == rhs.selection && lhs.spaceName == rhs.spaceName
    }

    var body: some View {
        let actions = CommandBarSearch.rowActions(for: result)
        let secondary = isHighlighted ? Color.white.opacity(0.8) : Color.secondary
        HStack(spacing: 10) {
            Image(systemName: Self.icon(for: result.kind))
                .foregroundStyle(secondary)
                .frame(width: 18)
            (Text(result.title).foregroundColor(isHighlighted ? .white : .primary)
                + Text(result.subtitle.map { " — \($0)" } ?? "").foregroundColor(secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if isHovering || isHighlighted {
                ForEach(actions, id: \.title) { action in
                    Button { onAction(action) } label: {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill((isHighlighted ? Color.white : Color.primary).opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(secondary)
                    .help(action == .deleteFromHistory ? "\(action.title) (⇧⌫)" : action.title)
                }
            }
            if let key = result.keyEquivalent, !key.isEmpty {
                Text(key)
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
            }
            if let spaceName {
                Text(spaceName)
                    .font(.system(size: 12, weight: isHighlighted ? .semibold : .regular))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHighlighted ? selection : Color.secondary)
                    .frame(width: 22, height: 20)
                    .background(isHighlighted ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(isHighlighted ? 0 : 0.35)))
                    .accessibilityLabel("Switch to Tab")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: CommandBarOverlay.rowHeight)
        .background(isHighlighted ? selection : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            ForEach(actions, id: \.title) { action in
                Button(action.title) { onAction(action) }
            }
        }
    }

    static func icon(for kind: CommandBarSearch.ResultKind) -> String {
        switch kind {
        case .openTab: return "square.stack"
        case .openURL: return "link"
        case .history: return "clock.arrow.circlepath"
        case .suggestion: return "magnifyingglass"
        case .search: return "magnifyingglass"
        case .command: return "command"
        }
    }
}

/// The scoped-search pill before the query (Arc `CommandBarInputScopedSearchPillView`).
private struct SiteSearchPill: View {
    let engine: SiteSearchEngine

    var body: some View {
        let color = Color(engine.color)
        Text(engine.name)
            .font(.callout.weight(.semibold))
            .foregroundStyle(engine.color.relativeLuminance > 0.5 ? Color.black : Color.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
            .accessibilityLabel("Searching \(engine.name)")
    }
}

/// "Search YouTube ⇥" at the end of the field while a site name is typed.
private struct TabToSearchHint: View {
    let engine: SiteSearchEngine

    var body: some View {
        HStack(spacing: 6) {
            Text("Search \(engine.name)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Tab")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.6)))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .help("Press Tab to search \(engine.name)")
    }
}
