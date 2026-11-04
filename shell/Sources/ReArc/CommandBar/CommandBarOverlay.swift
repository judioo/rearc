import SwiftUI
import SidebarModel

/// The centered floating URL/search panel (Cmd+T / Cmd+L). Enter submits,
/// Escape dismisses, arrow keys move through live results.
struct CommandBarOverlay: View {
    @Binding var text: String
    let results: [CommandBarSearch.Result]
    let highlightedIndex: Int
    var errorMessage: String?
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
                TextField(isCommandMode ? "Type a command…" : "Search or enter URL", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFieldFocused)
                    .onSubmit(onSubmit)
            }
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
                            resultRow(result, isHighlighted: index == highlightedIndex)
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

    @ViewBuilder
    private func resultRow(_ result: CommandBarSearch.Result, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: result.kind))
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private func icon(for kind: CommandBarSearch.ResultKind) -> String {
        switch kind {
        case .openTab: return "square.stack"
        case .openURL: return "link"
        case .history: return "clock.arrow.circlepath"
        case .search: return "magnifyingglass"
        case .command: return "command"
        }
    }
}
