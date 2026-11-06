import Foundation

/// Arc's tab stacking (ARC-RECORDING-2026-11-06 §8): a split is one sidebar
/// row. Until it has a name or an icon its panes sit side by side as chips;
/// with either it reads like a tab, "<icon> <name>".
extension SplitViewItem {
    /// Arc refuses a fifth pane.
    public static let maxPanes = 4
    /// Arc's toast for a fifth pane (`Letting user know they have maxed out
    /// the current panes`).
    public static let fullMessage = "Cannot Add New Pane"

    public var isFull: Bool { tabs.count >= Self.maxPanes }

    /// Arc's default name counts the panes.
    public var defaultTitle: String { "\(tabs.count) Tabs" }

    public var displayTitle: String { title ?? defaultTitle }

    /// Whether the row shows one icon and name instead of the pane chips.
    public var showsAsNamedRow: Bool { title != nil || customIcon != nil }

    /// Arc's chips keep titles up to three panes; four show favicons only.
    public var showsPaneTitles: Bool { tabs.count < Self.maxPanes }
}

/// What dropping a sidebar tab on the middle of a tab or split row did.
public enum SplitCombineOutcome: Equatable {
    case combined(SplitViewItem.ID)
    /// The split already has four panes: Arc keeps the tab and shows
    /// `SplitViewItem.fullMessage`.
    case full
    case refused
}

extension SidebarStore {

    /// Whether a sidebar tab can be dropped on the middle of `targetID`'s row
    /// (a plain tab at a section's root, or a split) to stack them. A full
    /// split still takes the drop so it can say why.
    public func canCombineIntoSplit(_ draggedID: UUID, onto targetID: UUID) -> Bool {
        if let target = split(withID: targetID) {
            return isSplitCandidate(draggedID, joining: target.focusTabID)
        }
        guard tab(withID: targetID) != nil, case .section = parent(of: targetID) else { return false }
        return canSplit(draggedID, onto: targetID)
    }

    /// Stacks the dragged tab with the target row: a tab makes a two-pane
    /// split in its place, a split takes it as its last pane.
    @discardableResult
    public func combineIntoSplit(_ draggedID: UUID, onto targetID: UUID) -> SplitCombineOutcome {
        guard canCombineIntoSplit(draggedID, onto: targetID) else { return .refused }
        let anchorID: Tab.ID
        if let target = split(withID: targetID) {
            guard !target.isFull else { return .full }
            anchorID = target.focusTabID
        } else {
            anchorID = targetID
        }
        return splitTab(draggedID, with: anchorID).map { .combined($0.id) } ?? .refused
    }

    /// Whether `tabID` would be refused only because `anchorID`'s split is full.
    public func isSplitFull(joining anchorID: Tab.ID) -> Bool {
        splitContaining(tabID: anchorID)?.split.isFull ?? false
    }

    /// Names the collection. Blank, or Arc's own "N Tabs", clears the name
    /// so the default keeps counting the panes.
    @discardableResult
    public func renameSplit(_ splitID: SplitViewItem.ID, to title: String) -> Bool {
        guard var split = split(withID: splitID) else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty || trimmed == split.defaultTitle ? nil : trimmed
        guard name != split.title else { return true }
        split.title = name
        replaceSplit(split)
        notifyMutation(.upsertItem(id: splitID))
        return true
    }
}

extension SplitViewItem {
    /// Copy Links and Arc's "Copy links as Markdown": one pane per line.
    public func links(markdown: Bool) -> String {
        tabs.map { markdown ? PageLinkCopyFormat.markdownLink(url: $0.url, title: $0.displayTitle) : $0.url.absoluteString }
            .joined(separator: "\n")
    }
}
