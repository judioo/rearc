import AppKit
import SwiftUI
import SidebarModel

/// One space's sidebar list as an AppKit table (perf-5). SwiftUI's
/// `ScrollView` + `LazyVStack` flushed the list's graph, placed its lazy
/// rows and walked every accessibility responder on each scroll step. Here
/// `NSTableView` virtualises the rows: a scroll step moves layers, and each
/// visible row is its own small `NSHostingView`, reused as rows scroll by.
///
/// The row list comes from `SidebarListController`, which observes the
/// space's outline, expansion and peeked selections and turns a change into
/// row inserts and removals. A change inside one row (its title, selection,
/// loading ring) stays in that row's hosting view.
///
/// Environment does not cross a hosting view, so the values rows read are
/// carried into each cell (`SidebarListCellContext`).
struct SidebarListTable: NSViewRepresentable {
    let model: BrowserViewModel
    let spaceID: Space.ID
    var tint: Color
    @Binding var draggedItemID: UUID?
    @Binding var dropState: SidebarDropState?
    @Environment(\.themeChrome) private var chrome
    @Environment(\.sidebarWindow) private var window
    @Environment(\.spacePager) private var pager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarCoveredByLibrary) private var covered

    func makeCoordinator() -> SidebarListController {
        SidebarListController(model: model, spaceID: spaceID, context: SidebarListCellContext(
            chrome: chrome, window: window, pager: pager, colorScheme: colorScheme, tint: tint
        ))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        sync(controller)
        let view = controller.makeScrollView()
        view.isHidden = covered
        return view
    }

    /// Under the Library the table is hidden, not rebuilt, so AppKit never
    /// hands it a click meant for the Library.
    func updateNSView(_ view: NSScrollView, context: Context) {
        sync(context.coordinator)
        if view.isHidden != covered { view.isHidden = covered }
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: SidebarListController) {
        coordinator.invalidate()
    }

    /// Takes the size it is offered: the window never measures the list.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    private func sync(_ controller: SidebarListController) {
        let cells = controller.context
        if cells.chrome != chrome { cells.chrome = chrome }
        if cells.window != window { cells.window = window }
        if cells.pager !== pager { cells.pager = pager }
        if cells.colorScheme != colorScheme { cells.colorScheme = colorScheme }
        if cells.tint != tint { cells.tint = tint }
        let dragged = $draggedItemID, drop = $dropState
        cells.writeDragged = { dragged.wrappedValue = $0 }
        cells.writeDropState = { drop.wrappedValue = $0 }
        if cells.draggedItemID != draggedItemID { cells.draggedItemID = draggedItemID }
        if cells.dropState != dropState { cells.dropState = dropState }
        controller.reduceMotion = reduceMotion
        controller.update(spaceID: spaceID, isDragging: draggedItemID != nil)
    }
}

/// What every cell of one list reads besides the model: the sidebar's
/// environment and the drag in progress. Observed, so a theme change or a
/// drag update redraws the visible cells without configuring them again.
@Observable
final class SidebarListCellContext {
    var chrome: ThemeChromeColors
    var window: SidebarWindowID?
    var pager: SpacePagerController?
    var colorScheme: ColorScheme
    var tint: Color
    var draggedItemID: UUID?
    var dropState: SidebarDropState?
    /// The sidebar's own bindings; the mirrors above follow at once so a
    /// cell sees its write before SwiftUI updates the table.
    @ObservationIgnored var writeDragged: (UUID?) -> Void = { _ in }
    @ObservationIgnored var writeDropState: (SidebarDropState?) -> Void = { _ in }

    init(chrome: ThemeChromeColors, window: SidebarWindowID?, pager: SpacePagerController?, colorScheme: ColorScheme, tint: Color) {
        self.chrome = chrome
        self.window = window
        self.pager = pager
        self.colorScheme = colorScheme
        self.tint = tint
    }

    var draggedBinding: Binding<UUID?> {
        Binding(get: { self.draggedItemID }, set: { value in
            self.draggedItemID = value
            self.writeDragged(value)
        })
    }

    var dropStateBinding: Binding<SidebarDropState?> {
        Binding(get: { self.dropState }, set: { value in
            self.dropState = value
            self.writeDropState(value)
        })
    }
}

/// The table's data source: the flattened rows, their heights, and the
/// observation that keeps both current.
final class SidebarListController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSGestureRecognizerDelegate {
    let model: BrowserViewModel
    private(set) var spaceID: Space.ID
    let context: SidebarListCellContext
    var reduceMotion = false
    private(set) var rows: [SidebarListRow] = []
    private var isDragging = false
    private var measured: [SidebarListRow.ID: Double] = [:]
    private let heights = SidebarListHeights.sidebar
    private weak var tableView: NSTableView?
    private var isActive = true
    private var heightsPending: Set<SidebarListRow.ID> = []
    private var shownSelection: UUID?
    private var externalDrag = false
    private var externalDragTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// A scroll gesture is moving the list: rows passing under a still
    /// pointer stay plain until it ends.
    private(set) var isLiveScrolling = false
    /// A context menu is open; the row it came from stays live.
    private(set) var isMenuTracking = false
    /// Every visible plain row hosts its SwiftUI row: a drag is under way,
    /// so the rows' own drop targets must be there.
    var hostsAllRows: Bool { isDragging || externalDrag }
    /// Tab cards and folder lists for rows under the pointer.
    private(set) lazy var hoverPreview = SidebarHoverPreview(controller: self)
    /// Holds the keyboard while this list has a multi-row selection, so ⌘C
    /// copies its links and Esc drops it; the page gets it back after.
    private let selectionKeys = SidebarSelectionKeyView()
    private weak var focusBeforeSelection: NSResponder?

    static let cellID = NSUserInterfaceItemIdentifier("SidebarListCell")
    static let plainCellID = NSUserInterfaceItemIdentifier("SidebarPlainRow")
    static let rowViewID = NSUserInterfaceItemIdentifier("SidebarListRow")
    /// Larger changes (a Clear, a space's first load) reload all rows at once.
    static let animatedChangeLimit = 24
    /// Arc's folder disclosure (2026-11-09 recording, 60 fps): children
    /// slide down and fade in over about 11 frames, and fold away in about 6.
    static let expandDuration: TimeInterval = 0.18
    static let collapseDuration: TimeInterval = 0.1

    init(model: BrowserViewModel, spaceID: Space.ID, context: SidebarListCellContext) {
        self.model = model
        self.spaceID = spaceID
        self.context = context
    }

    func makeScrollView() -> NSScrollView {
        let table = SidebarTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.gridStyleMask = []
        table.focusRingType = .none
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        tableView = table

        let scroll = SidebarScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .allowed
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        let emptySpaceClick = NSClickGestureRecognizer(target: self, action: #selector(openTabFromEmptySpace(_:)))
        emptySpaceClick.numberOfClicksRequired = 2
        emptySpaceClick.delaysPrimaryMouseButtonEvents = false
        emptySpaceClick.delegate = self
        scroll.addGestureRecognizer(emptySpaceClick)
        rebuild(animated: false, reloadAll: true)
        trackSelection()
        observeInteraction(scroll)
        selectionKeys.onCopy = { [weak self] in
            guard let self, let ids = model.store.multiSelectedIDs(in: context.window) else { return false }
            model.copyLinks(of: ids)
            return true
        }
        selectionKeys.onCancel = { [weak self] in
            guard let self else { return false }
            guard model.store.multiSelection(in: context.window) != nil else { return false }
            model.clearSelection(in: context.window)
            return true
        }
        selectionKeys.hasSelection = { [weak self] in
            self.map { $0.model.store.multiSelectedIDs(in: $0.context.window) != nil } ?? false
        }
        scroll.addSubview(selectionKeys)
        trackMultiSelection()
        return scroll
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let tableView, let scroll = tableView.enclosingScrollView,
              scroll.contentView.bounds.contains(gestureRecognizer.location(in: scroll.contentView)) else { return false }
        let point = gestureRecognizer.location(in: tableView)
        let bottom = tableView.numberOfRows > 0 ? tableView.rect(ofRow: tableView.numberOfRows - 1).maxY : 0
        return SidebarEmptySpaceClick.opensNewTab(clickCount: 2, rowIndex: tableView.row(at: point),
                                                  y: point.y, rowsBottom: bottom)
    }

    @objc private func openTabFromEmptySpace(_ recognizer: NSClickGestureRecognizer) {
        guard gestureRecognizerShouldBegin(recognizer) else { return }
        model.newTab()
    }

    func invalidate() {
        isActive = false
        tableView?.dataSource = nil
        tableView?.delegate = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        externalDragTimer?.invalidate()
        hoverPreview.invalidate()
    }

    // MARK: Live rows

    private func observeInteraction(_ scroll: NSScrollView) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLiveScrolling = true
                    self?.hoverPreview.cancel()
                }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLiveScrolling = false
                    self?.syncPlainCells()
                }
            },
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isMenuTracking = true
                    self?.hoverPreview.cancel()
                    self?.dropSelectionForMenuOutsideIt()
                }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hoverPreview.cancel() }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isMenuTracking = false
                    self?.syncPlainCells()
                }
            },
        ]
    }

    /// A row's context menu opened on a row outside the selection: the menu
    /// acts on that row alone (`SidebarStore.menuTargets`) and the selection goes.
    private func dropSelectionForMenuOutsideIt() {
        guard let table = tableView, let event = NSApp.currentEvent, event.window === table.window,
              event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return }
        let index = table.row(at: table.convert(event.locationInWindow, from: nil))
        guard rows.indices.contains(index), case .item(let item, _) = rows[index],
              model.store.multiSelection(in: context.window)?.spaceID == spaceID,
              !model.store.isMultiSelected(item.id, in: context.window) else { return }
        model.clearSelection(in: context.window)
    }

    // MARK: Keyboard for a selection

    /// Takes the keyboard when this list's window gets a selection in its
    /// space, and hands it back to what had it when the selection ends.
    private func trackMultiSelection() {
        guard isActive else { return }
        let selected = withObservationTracking {
            model.store.multiSelection(in: context.window)?.spaceID == spaceID
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.trackMultiSelection() }
        }
        guard let window = selectionKeys.window else { return }
        if selected {
            guard window.firstResponder !== selectionKeys else { return }
            focusBeforeSelection = window.firstResponder
            window.makeFirstResponder(selectionKeys)
        } else if window.firstResponder === selectionKeys {
            let previous = (focusBeforeSelection as? NSView).flatMap { $0.window === window ? $0 : nil }
            window.makeFirstResponder(previous)
            focusBeforeSelection = nil
        }
    }

    /// Each visible plain row re-reads the pointer and whether it should be live.
    private func syncPlainCells() {
        tableView?.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? SidebarPlainRowCell)?.syncPointer()
        }
    }

    /// A link or file dragged over a plain row from a page or another app.
    /// The rows stay live until the button comes up.
    func noteExternalDrag() {
        guard !externalDrag else { return }
        externalDrag = true
        syncPlainCells()
        externalDragTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons == 0 else { return }
                timer.invalidate()
                self.externalDragTimer = nil
                self.externalDrag = false
                self.syncPlainCells()
            }
        }
    }

    /// The SwiftUI row a plain cell hosts while it is live.
    func hostedRoot(for id: UUID, cell: SidebarPlainRowCell) -> SidebarHostedRow? {
        guard let row = rows.first(where: { $0.id == .item(id) }) else { return nil }
        return SidebarHostedRow(
            cell: SidebarListCell(row: row, model: model, spaceID: spaceID, context: context, onHeight: nil),
            onHover: { [weak cell] in cell?.hostedHoverChanged($0) }
        )
    }

    /// Accessibility's press on a plain row: what a click on the row does.
    func press(_ id: UUID, kind: SidebarOutlineNode.Kind) {
        switch kind {
        case .folder:
            model.store.toggleFolderExpanded(id)
        default:
            model.selectTab(id)
        }
    }

    /// Tab and folder rows draw in AppKit; the others are SwiftUI cells.
    static func isPlain(_ row: SidebarListRow) -> Bool {
        guard case .item(let item, _) = row else { return false }
        return item.node.kind == .tab || item.node.kind == .folder
    }

    /// From the representable: a different space reloads; a drag starting or
    /// ending adds or takes away the section drop rows.
    func update(spaceID: Space.ID, isDragging: Bool) {
        guard spaceID != self.spaceID || isDragging != self.isDragging else { return }
        let spaceChanged = spaceID != self.spaceID
        let dragChanged = isDragging != self.isDragging
        self.spaceID = spaceID
        self.isDragging = isDragging
        if spaceChanged { measured = [:] }
        rebuild(animated: false, reloadAll: spaceChanged)
        if dragChanged { syncPlainCells() }
    }

    // MARK: Rows

    /// Reads the rows under observation; any change the rows depend on
    /// schedules one rebuild on the next turn of the main queue.
    private func observedRows() -> [SidebarListRow] {
        withObservationTracking {
            let store = model.store
            let spaceID = spaceID
            return SidebarListRow.rows(
                outline: store.outline(for: spaceID),
                expanded: store.expandedFolderIDs,
                pinnedCollapsed: model.isPinnedSectionCollapsed(spaceID: spaceID, in: context.window),
                isDragging: isDragging,
                selection: { store.selection(among: $0, inSpace: spaceID) }
            )
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.rebuild(animated: true) }
        }
    }

    private func rebuild(animated: Bool, reloadAll: Bool = false) {
        guard isActive else { return }
        let new = observedRows()
        let old = rows
        let diff = SidebarListDiff.between(old, new)
        guard let table = tableView else {
            rows = new
            return
        }
        guard !diff.isEmpty || reloadAll else { return }
        let ids = Set(new.map(\.id))
        measured = measured.filter { ids.contains($0.key) }
        guard !reloadAll, !old.isEmpty, diff.structuralCount <= Self.animatedChangeLimit else {
            rows = new
            table.reloadData()
            return
        }
        // Small changes keep the other rows' cells where they are (a drag's
        // source cell among them). Folder children slide out from under their
        // folder and fade, opening or closing the rows' height as Arc does.
        let animate = animated && !reduceMotion && table.window != nil
        let insertion: NSTableView.AnimationOptions = animate ? [.effectFade, .slideDown] : []
        let removal: NSTableView.AnimationOptions = animate ? [.effectFade, .slideUp] : []
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = animate ? (diff.inserted.isEmpty ? Self.collapseDuration : Self.expandDuration) : 0
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            table.beginUpdates()
            rows = new
            if !diff.removed.isEmpty { table.removeRows(at: diff.removed, withAnimation: removal) }
            if !diff.inserted.isEmpty { table.insertRows(at: diff.inserted, withAnimation: insertion) }
            table.endUpdates()
        }
        if !diff.reloaded.isEmpty {
            table.reloadData(forRowIndexes: diff.reloaded, columnIndexes: IndexSet(integer: 0))
            table.noteHeightOfRows(withIndexesChanged: diff.reloaded)
        }
    }

    // MARK: Scroll to the selection

    /// Keeps the space's selection in view when it changes (a shortcut, ⌃Tab,
    /// a new tab), the way Arc's outline does.
    private func trackSelection() {
        guard isActive else { return }
        let selected = withObservationTracking {
            model.store.selectedItemID(inSpace: spaceID)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                // After the rows' own rebuild, which is queued the same way.
                DispatchQueue.main.async { self?.trackSelection() }
            }
        }
        defer { shownSelection = selected }
        guard let selected, selected != shownSelection else { return }
        scrollToVisible(selected)
    }

    private func scrollToVisible(_ id: UUID) {
        guard let table = tableView, table.window != nil else { return }
        let index = rows.firstIndex { row in
            guard case .item(let item, _) = row else { return false }
            return item.id == id || (item.node.kind == .split && model.store.split(withID: item.id)?.tabs.contains { $0.id == id } == true)
        }
        guard let index else { return }
        if !table.visibleRect.contains(table.rect(ofRow: index)) { table.scrollRowToVisible(index) }
    }

    // MARK: Heights

    /// A measured row reports its content height; the table hears of it on
    /// the next turn, outside the cell's own layout pass.
    fileprivate func measuredHeight(_ height: Double, for id: SidebarListRow.ID) {
        guard isActive, abs((measured[id] ?? 0) - height) > 0.5 else { return }
        measured[id] = height
        let first = heightsPending.isEmpty
        heightsPending.insert(id)
        guard first else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let table = tableView else { return }
            let pending = heightsPending
            heightsPending = []
            var indexes = IndexSet()
            for (index, row) in rows.enumerated() where pending.contains(row.id) { indexes.insert(index) }
            if !indexes.isEmpty {
                NSAnimationContext.runAnimationGroup { animation in
                    animation.duration = 0
                    table.noteHeightOfRows(withIndexesChanged: indexes)
                }
            }
        }
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 1 }
        let item = rows[row]
        return CGFloat(heights.height(item, measured: measured[item.id]))
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let view = tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? SidebarTableRowView { return view }
        let view = SidebarTableRowView()
        view.identifier = Self.rowViewID
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        if Self.isPlain(item), case .item(let outline, _) = item {
            SidebarListCellCounters.configures += 1
            let cell = tableView.makeView(withIdentifier: Self.plainCellID, owner: nil) as? SidebarPlainRowCell ?? {
                let cell = SidebarPlainRowCell()
                cell.identifier = Self.plainCellID
                return cell
            }()
            cell.configure(row: outline, controller: self)
            return cell
        }
        let measures = heights.fixed(item) == nil
        let root = SidebarListCell(
            row: item, model: model, spaceID: spaceID, context: context,
            onHeight: measures ? { [weak self] in self?.measuredHeight($0, for: item.id) } : nil
        )
        if let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? SidebarListCellView {
            SidebarListCellCounters.configures += 1
            cell.hosting.rootView = root
            return cell
        }
        let cell = SidebarListCellView(root: root)
        cell.identifier = Self.cellID
        return cell
    }
}

extension SidebarListHeights {
    /// `SidebarMetrics`' pitch and header geometry.
    static let sidebar: SidebarListHeights = {
        var heights = SidebarListHeights()
        heights.rowPitch = Double(SidebarMetrics.rowPitch)
        heights.header = Double(SidebarMetrics.headerHeight + SidebarMetrics.headerToFirstRow)
        return heights
    }()
}

/// The responder a list's multi-row selection holds the keyboard with:
/// Edit › Copy (⌘C) copies the selected rows' links, Esc drops the selection.
/// Other keys go on up the responder chain.
final class SidebarSelectionKeyView: NSView, NSMenuItemValidation {
    var onCopy: () -> Bool = { false }
    var onCancel: () -> Bool = { false }
    var hasSelection: () -> Bool = { false }

    override var acceptsFirstResponder: Bool { true }

    @objc func copy(_ sender: Any?) {
        if !onCopy() { NSSound.beep() }
    }

    override func cancelOperation(_ sender: Any?) {
        if !onCancel() { super.cancelOperation(sender) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, onCancel() { return }
        super.keyDown(with: event)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(copy(_:)) ? hasSelection() : true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A table that never takes keyboard focus or draws a selection, and lets
/// clicks reach the SwiftUI rows inside its cells.
/// Responsive scrolling takes a gesture's events after the first straight off
/// the queue, past `sendEvent`, so the space-swipe monitor (a local event
/// monitor) only ever saw a swipe begin and the pager was left mid-swipe.
private final class SidebarScrollView: NSScrollView {
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
}

private final class SidebarTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// A row view with nothing of its own to draw: the SwiftUI row draws its
/// hover and selected states.
private final class SidebarTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// How often the cells' hosting views lay out and are handed a new row.
/// The bench's scroll scenario reads and resets them per iteration (perf-6):
/// a scroll step should lay out only the newly configured cells.
enum SidebarListCellCounters {
    @MainActor static var layouts = 0
    @MainActor static var configures = 0
    /// Plain rows that started hosting their SwiftUI row (perf-7).
    @MainActor static var hostings = 0
}

/// A reusable cell: one hosting view filling it.
private final class SidebarListCellView: NSView {
    let hosting: NSHostingView<SidebarListCell>

    init(root: SidebarListCell) {
        hosting = SidebarCountingHostingView(rootView: root)
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = bounds
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
}

/// One cell's SwiftUI root: the carried environment, then the row. The row
/// id is the content's identity, so a reused cell starts the new row with
/// fresh state (hover, rename) instead of the last one's.
struct SidebarListCell: View {
    let row: SidebarListRow
    let model: BrowserViewModel
    let spaceID: Space.ID
    let context: SidebarListCellContext
    /// Set for rows that size to their content.
    let onHeight: ((Double) -> Void)?

    var body: some View {
        content
            .id(row.id)
            .padding(.horizontal, SidebarMetrics.rowInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(context.chrome.title)
            .tint(context.tint)
            .environment(\.themeChrome, context.chrome)
            .environment(\.sidebarWindow, context.window)
            .environment(\.spacePager, context.pager)
            .environment(\.colorScheme, context.colorScheme)
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        if let onHeight {
            rowContent
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { onHeight($0) }
        } else {
            rowContent
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        switch row {
        case .header:
            SidebarHeaderCell(model: model, spaceID: spaceID)
        case .item(let item, _):
            SidebarEntryRow(
                id: item.id,
                depth: item.depth,
                spaceID: spaceID,
                model: model,
                dropPosition: context.dropState?.targetID == item.id ? context.dropState?.position : nil,
                draggedItemID: context.draggedBinding,
                dropState: context.dropStateBinding
            )
            .equatable()
        case .todayDivider:
            SidebarTodayCell(model: model, spaceID: spaceID)
        case .newTab:
            NewTabRowView { model.newTab() }
        case .sectionEnd(let section, let isEmpty):
            SectionEndDropZone(
                destination: .section(spaceID: spaceID, section: section),
                placeholder: isEmpty ? (section == .pinned ? "Drop here to pin" : "Drop here to unpin") : nil,
                model: model,
                draggedItemID: context.draggedBinding,
                dropState: context.dropStateBinding
            )
        }
    }
}

/// The space header row. It reads the space, whether Pinned has rows and
/// its collapse here, in the cell, so only this cell redraws for them.
private struct SidebarHeaderCell: View {
    let model: BrowserViewModel
    let spaceID: Space.ID
    @Environment(\.sidebarWindow) private var window

    var body: some View {
        let space = model.store.space(withID: spaceID) ?? model.space(in: window)
        let collapsed = model.isPinnedSectionCollapsed(spaceID: space.id, in: window)
        SpaceHeaderView(
            model: model,
            space: space,
            hasPinned: !model.store.outline(for: space.id).pinned.isEmpty,
            isPinnedCollapsed: collapsed,
            onTogglePinned: { model.togglePinnedSection(spaceID: space.id, in: window) }
        )
        .padding(.bottom, SidebarMetrics.headerToFirstRow)
    }
}

/// The Today divider row; it reads whether Today has tabs in the cell.
private struct SidebarTodayCell: View {
    let model: BrowserViewModel
    let spaceID: Space.ID

    var body: some View {
        TodayHeaderView(model: model, spaceID: spaceID, hasTabs: !model.store.outline(for: spaceID).today.isEmpty)
    }
}
