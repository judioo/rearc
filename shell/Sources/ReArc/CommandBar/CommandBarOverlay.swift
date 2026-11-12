import SwiftUI
import SidebarModel

/// The centered floating URL/search card (Cmd+T / Cmd+L), drawn to Arc's
/// measurements (COMMAND-BAR §10): an opaque card in the window's own
/// neutral surface over an undimmed page, the selected row a solid accent
/// fill. Enter submits, Escape dismisses, arrow keys move through live
/// results. A shortcut's keyword, or a site the field completes to, offers
/// "Search cushwake" / "Ask ChatGPT" with a Tab keycap; Tab (or a click on
/// the hint) puts its chip in the field, the list collapses to the field
/// alone, and Delete on an empty query takes the chip off (§4.2). Rows offer
/// Copy URL and, for history, Remove from History on hover or highlight and
/// in their context menu; Shift+Delete removes the highlighted history row
/// (§6.4). A typed domain or an earlier query completes inline (Right Arrow
/// takes it), and ⌘↩ / ⌥↩ / ⇧↩ open a page result in a new tab, a split or
/// Little Arc (§3, §6.3).
struct CommandBarOverlay: View {
    @Environment(\.themeChrome) private var themeChrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var text: String
    /// The inline completion's remainder after the typed text.
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
    /// The chip's and its rows' fill (`BrowserViewModel.commandBarSiteFill`).
    var siteSearchFill: SpaceColor?
    /// Bumped as the list collapses to the field: the tint and pulse play.
    var collapseCount = 0
    /// Tab: returns true when it entered a site search.
    var onTab: () -> Bool = { false }
    /// Delete on an empty field: returns true when it removed the chip.
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
    var width: CGFloat = CommandBarOverlay.arcWidth
    /// The space a switch-to-tab row's tab lives in, when it is not the shown one.
    var spaceName: (Space.ID) -> String? = { _ in nil }
    /// A row's site icon, when cached.
    var favicon: (URL) -> NSImage? = { _ in nil }

    // Arc's card, measured on the 2026-11-12 recordings (1 px = 1 pt):
    // 765 × (64 + 13 + 50 per row), corners ≈ 10, a hairline edge.
    static let arcWidth: CGFloat = 765
    static let cornerRadius: CGFloat = 10
    static let fieldHeight: CGFloat = 64
    static let rowHeight: CGFloat = 45
    static let rowSpacing: CGFloat = 5
    static let listTopPadding: CGFloat = 7
    static let listBottomPadding: CGFloat = 11
    /// Rows inset from the card's sides; the selected fill's corners.
    static let rowInset: CGFloat = 10
    static let rowCornerRadius: CGFloat = 7
    /// The magnifier's and the text column's x in the card.
    static let glyphX: CGFloat = 25
    static let textX: CGFloat = 51
    static let fieldFontSize: CGFloat = 18
    static let rowFontSize: CGFloat = 13
    /// Rows shown before the list scrolls.
    static let maxVisibleRows = 8
    /// The bar's top sits 38 % of the way down the window.
    static let topFraction: CGFloat = 0.38
    /// The recoloured rows stay this long after Tab, then the list cuts to
    /// the field (Arc: 1.1 s and 1.8 s, waiting on its own lookup; ReArc a fixed beat).
    static let collapseHold: TimeInterval = 0.5
    /// The collapse's tint fades over this long (Arc ≈ 0.25 s) …
    static let collapseTintDuration: TimeInterval = 0.25
    /// … while the card dips to this scale and springs back (Arc ≈ 0.17 s).
    static let collapsePulseScale: CGFloat = 0.99

    /// The list's height for `rows` rows: Arc's cut, no tween.
    static func listHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        let shown = CGFloat(min(rows, maxVisibleRows))
        return listTopPadding + shown * rowHeight + (shown - 1) * rowSpacing + listBottomPadding
    }

    private var isCommandMode: Bool { text.hasPrefix(">") }

    @FocusState private var isFieldFocused: Bool
    @State private var earlyKeys = EarlyKeyCatcher()
    @State private var collapseTint = 0.0
    @State private var pulseScale: CGFloat = 1

    var body: some View {
        let dark = themeChrome.isWindowDark
        let surface = Color(CommandBarInk.surface(dark: dark))
        VStack(alignment: .leading, spacing: 0) {
            field(dark: dark)
                .frame(height: Self.fieldHeight)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, Self.textX)
                    .padding(.bottom, 8)
            }

            if !results.isEmpty {
                Rectangle()
                    .fill(Color(CommandBarInk.separator(dark: dark)))
                    .frame(height: 1)
                    .padding(.horizontal, 11)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                        // Rows keep their slot, so a keystroke or an engine
                        // answer updates the visible rows in place instead of
                        // building new ones (5.5 → 2.3 ms for 12 changed rows),
                        // and equal rows skip their body. Hover stays with the
                        // row under the pointer.
                        let selection = Color(selectionFill)
                        ForEach(results.indices, id: \.self) { index in
                            let result = results[index]
                            CommandBarResultRow(
                                result: result,
                                isHighlighted: index == highlightedIndex,
                                selection: selection,
                                dark: dark,
                                spaceName: result.kind == .openTab ? result.spaceID.flatMap(spaceName) : nil,
                                icon: result.destinationURL.flatMap { result.kind == .search ? nil : favicon($0) },
                                onAction: { onRowAction($0, result) },
                                onSelect: { onSelectResult(result.id) }
                            )
                            .equatable()
                        }
                    }
                    .padding(.top, Self.listTopPadding)
                    .padding(.bottom, Self.listBottomPadding)
                }
                .scrollDisabled(results.count <= Self.maxVisibleRows)
                .frame(height: Self.listHeight(rows: results.count))
            }
        }
        .frame(width: width)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(surface)
                .overlay {
                    // The collapse washes the card with the site's colour, then fades.
                    if collapseTint > 0, let siteSearchFill {
                        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                            .fill(Color(siteSearchFill).opacity(collapseTint))
                    }
                }
                // Arc's shadow, fitted to the measured falloff: 35 % darker 8 pt
                // below the card, 12 % at 64 pt, gone by ≈ 110 pt; 25 % at the sides.
                .shadow(color: .black.opacity(dark ? 0.7 : 0.6), radius: 40, y: 24)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.black.opacity(dark ? 0.6 : 0.2), lineWidth: 1)
        )
        .scaleEffect(pulseScale)
        .onChange(of: collapseCount) { _, _ in playCollapse() }
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

    /// The magnifier, the chip, the text and, at the end, the Tab hint.
    @ViewBuilder
    private func field(dark: Bool) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(CommandBarInk.primaryText(dark: dark)))
                .frame(width: Self.textX - Self.glyphX + 12, alignment: .leading)
                .padding(.leading, Self.glyphX - 1)
            if let siteSearch {
                SiteSearchChip(engine: siteSearch, fill: Color(siteSearchFill ?? themeChrome.commandBarFill))
                    .padding(.trailing, 8)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: Self.fieldFontSize))
                .foregroundStyle(Color(CommandBarInk.primaryText(dark: dark)))
                // Not a credential: AppKit then skips its password AutoFill
                // check as the field takes the keyboard (≈ 3 ms on ⌘T / ⌘L).
                .textContentType(.URL)
                .focused($isFieldFocused)
                .overlay(alignment: .leading) { inlineCompletion(dark: dark) }
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
                Button { _ = onTab() } label: {
                    TabToSearchHint(engine: siteSearchSuggestion, dark: dark)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
        }
        .padding(.trailing, 22)
    }

    /// Plays the collapse once: the card washed with the site's colour
    /// (17 %) fading out, and a slight dip and spring back. Reduce Motion
    /// keeps the cut alone.
    private func playCollapse() {
        guard !reduceMotion, siteSearchFill != nil else { return }
        collapseTint = CommandBarInk.collapseTint
        withAnimation(.easeOut(duration: Self.collapseTintDuration)) { collapseTint = 0 }
        withAnimation(.easeOut(duration: 0.07)) { pulseScale = Self.collapsePulseScale }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.8)) { pulseScale = 1 }
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

    /// The selected row's fill: the space's accent, or the site's colour
    /// with a chip, each fitted for white text (`CommandBarInk`).
    private var selectionFill: SpaceColor {
        siteSearch == nil ? themeChrome.commandBarFill : (siteSearchFill ?? themeChrome.commandBarFill)
    }

    /// The typed text, invisible, then the completion's remainder as Arc
    /// shows it: in the text colour on a pale wash of the selection, as if selected.
    @ViewBuilder
    private func inlineCompletion(dark: Bool) -> some View {
        if let inlineSuffix, !inlineSuffix.isEmpty {
            HStack(spacing: 0) {
                Text(text).foregroundColor(.clear)
                Text(inlineSuffix)
                    .foregroundColor(Color(CommandBarInk.primaryText(dark: dark)))
                    .background(Color(selectionFill).opacity(0.3))
            }
            .font(.system(size: Self.fieldFontSize))
            .lineLimit(1)
            .allowsHitTesting(false)
            .accessibilityLabel("Completes to \(text + inlineSuffix)")
        }
    }

    private var placeholder: String {
        if let siteSearch { return siteSearch.placeholder }
        return isCommandMode ? "Type a command…" : "Search or Enter URL…"
    }
}

/// One result on one line: icon, title, then "— subtitle" in grey; at the
/// right, the row's action hint ("Switch to Tab" and an → keycap, a
/// command's keys). The selected row is a rounded solid fill with white
/// text. Row actions show while hovered or selected. Equal rows skip their
/// body: the closures route through the model with this row's result, so a
/// kept closure acts the same.
struct CommandBarResultRow: View, Equatable {
    let result: CommandBarSearch.Result
    let isHighlighted: Bool
    let selection: Color
    var dark = false
    var spaceName: String?
    var icon: NSImage?
    let onAction: (CommandBarRowAction) -> Void
    let onSelect: () -> Void
    @State private var isHovering = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.result == rhs.result && lhs.isHighlighted == rhs.isHighlighted && lhs.dark == rhs.dark
            && lhs.selection == rhs.selection && lhs.spaceName == rhs.spaceName && lhs.icon === rhs.icon
    }

    var body: some View {
        let actions = CommandBarSearch.rowActions(for: result)
        let primary = isHighlighted ? Color(CommandBarInk.selectedText) : Color(CommandBarInk.primaryText(dark: dark))
        let secondary = isHighlighted ? Color(CommandBarInk.selectedText).opacity(0.85) : Color(CommandBarInk.secondaryText(dark: dark))
        HStack(spacing: 0) {
            rowIcon(secondary: secondary)
                .frame(width: 24, height: 24)
                .padding(.trailing, CommandBarOverlay.textX - CommandBarOverlay.rowInset - 10 - 24)
            (Text(result.title).foregroundColor(primary)
                + Text(subtitle.map { " — \($0)" } ?? "").foregroundColor(secondary).fontWeight(.regular))
                .font(.system(size: CommandBarOverlay.rowFontSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if isHovering || isHighlighted {
                ForEach(actions, id: \.title) { action in
                    Button { onAction(action) } label: {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isHighlighted ? Color.white.opacity(0.2) : Color(CommandBarInk.keycap(dark: dark))))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(secondary)
                    .help(action == .deleteFromHistory ? "\(action.title) (⇧⌫)" : action.title)
                    .padding(.leading, 6)
                }
            }
            if let key = result.keyEquivalent, !key.isEmpty {
                Text(key)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondary)
            }
            if result.kind == .openTab {
                Text("Switch to Tab")
                    .font(.system(size: CommandBarOverlay.rowFontSize, weight: .semibold))
                    .foregroundStyle(secondary)
                    .padding(.leading, 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHighlighted ? selection : Color(CommandBarInk.secondaryText(dark: dark)))
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHighlighted ? Color.white : Color(CommandBarInk.keycap(dark: dark))))
                    .padding(.leading, 8)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 13)
        .frame(height: CommandBarOverlay.rowHeight)
        .background(isHighlighted ? selection : Color.clear, in: RoundedRectangle(cornerRadius: CommandBarOverlay.rowCornerRadius, style: .continuous))
        .padding(.horizontal, CommandBarOverlay.rowInset)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(result.kind == .command ? "" : "↩ Open · ⌘↩ New Tab · ⌥↩ Split View · ⇧↩ Little ReArc")
        .contextMenu {
            ForEach(actions, id: \.title) { action in
                Button(action.title) { onAction(action) }
            }
        }
    }

    /// A tab shows its space only when it is not the one on screen; a site
    /// search row shows the host its query goes to while it is selected.
    private var subtitle: String? {
        switch result.kind {
        case .openTab: return spaceName
        default: return result.siteSearchID != nil && !isHighlighted ? nil : result.subtitle.map(Self.shortened)
        }
    }

    /// Addresses as Arc writes them: no scheme, no trailing slash.
    static func shortened(_ subtitle: String) -> String {
        var text = subtitle
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    @ViewBuilder
    private func rowIcon(secondary: Color) -> some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .padding(4)
                .background(isHighlighted ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: Self.icon(for: result.kind))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondary)
        }
    }

    static func icon(for kind: CommandBarSearch.ResultKind) -> String {
        switch kind {
        case .openTab: return "square.stack"
        case .openURL: return "globe"
        case .history: return "clock.arrow.circlepath"
        case .suggestion: return "magnifyingglass"
        case .search: return "magnifyingglass"
        case .command: return "command"
        }
    }
}

/// The site search chip before the query (Arc `CommandBarInputScopedSearchPillView`):
/// the entry's own name on its colour, 24 pt tall.
private struct SiteSearchChip: View {
    let engine: SiteSearchEngine
    let fill: Color

    var body: some View {
        Text(engine.name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(CommandBarInk.selectedText))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(fill, in: Capsule())
            .fixedSize()
            .accessibilityLabel("\(engine.hint)")
    }
}

/// "Search cushwake  Tab" at the end of the field while a shortcut is offered.
private struct TabToSearchHint: View {
    let engine: SiteSearchEngine
    let dark: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(engine.hint)
                .font(.system(size: CommandBarOverlay.rowFontSize))
                .foregroundStyle(Color(CommandBarInk.secondaryText(dark: dark)))
                .lineLimit(1)
            Text("Tab")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(CommandBarInk.primaryText(dark: dark)).opacity(0.75))
                .frame(width: 31, height: 24)
                .background(Color(CommandBarInk.keycap(dark: dark)), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .fixedSize()
        .contentShape(Rectangle())
        .help("Press Tab to \(engine.verb.lowercased()) \(engine.name)")
        .accessibilityLabel("\(engine.hint), press Tab")
    }
}
