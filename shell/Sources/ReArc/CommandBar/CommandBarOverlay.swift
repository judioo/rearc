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
    let onSelectIndex: (Int) -> Void
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
    /// The bar's top sits 38 % of the way down the window.
    static let topFraction: CGFloat = 0.38

    private var isCommandMode: Bool { text.hasPrefix(">") }

    @FocusState private var isFieldFocused: Bool

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
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            CommandBarResultRow(
                                result: result,
                                isHighlighted: index == highlightedIndex,
                                selection: selectionColor,
                                spaceName: result.kind == .openTab ? result.spaceID.flatMap(spaceName) : nil,
                                onAction: { onRowAction($0, result) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { onSelectIndex(index) }
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(maxHeight: 300)
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
        .onAppear { isFieldFocused = true }
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
/// actions show while hovered or selected.
private struct CommandBarResultRow: View {
    let result: CommandBarSearch.Result
    let isHighlighted: Bool
    let selection: Color
    var spaceName: String?
    let onAction: (CommandBarRowAction) -> Void
    @State private var isHovering = false

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
        .frame(height: 34)
        .background(isHighlighted ? selection : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 8)
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
