import SwiftUI
import SidebarModel

/// The centered floating URL/search panel (Cmd+T / Cmd+L). Enter submits,
/// Escape dismisses, arrow keys move through live results. Typing a site's
/// name offers "Tab to search" it; Tab turns it into a pill and Delete on
/// an empty query removes it again (Arc site search, COMMAND-BAR §4.2).
/// Rows offer Copy URL and, for history, Remove from History on hover or
/// highlight and in their context menu; Shift+Delete removes the
/// highlighted history row (COMMAND-BAR §6.4).
struct CommandBarOverlay: View {
    @Binding var text: String
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
                    .onSubmit(onSubmit)
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
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            CommandBarResultRow(
                                result: result,
                                isHighlighted: index == highlightedIndex,
                                onAction: { onRowAction($0, result) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { onSelectIndex(index) }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear { isFieldFocused = true }
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

    private var placeholder: String {
        if let siteSearch { return "Search \(siteSearch.name)" }
        return isCommandMode ? "Type a command…" : "Search or enter URL"
    }
}

/// One result: icon, title and subtitle, and its row actions while hovered
/// or highlighted.
private struct CommandBarResultRow: View {
    let result: CommandBarSearch.Result
    let isHighlighted: Bool
    let onAction: (CommandBarRowAction) -> Void
    @State private var isHovering = false

    var body: some View {
        let actions = CommandBarSearch.rowActions(for: result)
        HStack(spacing: 10) {
            Image(systemName: Self.icon(for: result.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .lineLimit(1)
                if let subtitle = result.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isHovering || isHighlighted {
                ForEach(actions, id: \.title) { action in
                    Button { onAction(action) } label: {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(action == .deleteFromHistory ? "\(action.title) (⇧⌫)" : action.title)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
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
