import AppKit
import SwiftUI
import SidebarModel

/// Library › Downloads' list as an AppKit table of plain rows (perf-8).
///
/// The SwiftUI `LazyVStack` of `DownloadRowView`s spent its time in SwiftUI's
/// update and layout of the rows: ~60–115 ms building the first rows, single
/// dropped frames while scrolling 39k rows, ~1 s of stalls in a fling. Paging
/// the rows into SwiftUI did not help. As the sidebar did (perf-5, perf-7),
/// `NSTableView` virtualises the rows here, every row has the same height (so
/// the table never asks for 39k heights), and each cell is plain AppKit
/// views, reused as rows scroll by. Scrolling moves layers.
///
/// The row list comes from `DownloadsTableController`, which observes the
/// tray's list and its warnings and turns a change into row edits
/// (`DownloadTableRows`). Archived rows that page in from the engine's
/// history are appends at the end; a new download is an insert at the top.
struct DownloadsLibraryTable: NSViewRepresentable {
    let downloads: DownloadsController
    var query: String
    let state: DownloadsTableState
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> DownloadsTableController {
        DownloadsTableController(downloads: downloads, state: state, query: query)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = context.coordinator.makeScrollView()
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        return view
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if view.appearance?.name != appearance?.name { view.appearance = appearance }
        context.coordinator.setQuery(query)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: DownloadsTableController) {
        coordinator.invalidate()
    }

    /// Takes the size it is offered: the window never measures the list.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// What the page around the table reads: whether it shows any row (the
/// empty state), set only when it changes so the page does not redraw for
/// a transfer's progress.
@Observable
final class DownloadsTableState {
    /// False until the table has looked, so its first frame is the rows, not the empty state.
    private(set) var isEmpty = false
    /// The tray holds no download at all ("No downloads yet", not "No matches").
    private(set) var hasNoDownloads = true
    @ObservationIgnored weak var controller: DownloadsTableController?

    func set(isEmpty: Bool, hasNoDownloads: Bool) {
        if self.isEmpty != isEmpty { self.isEmpty = isEmpty }
        if self.hasNoDownloads != hasNoDownloads { self.hasNoDownloads = hasNoDownloads }
    }
}

/// Plain rows' geometry: `DownloadRowView`'s, on one 48 pt pitch.
enum DownloadsTableMetrics {
    /// 46 pt rows 2 pt apart; a transfer's bar fits between its name and
    /// status, and Keep or Discard sit at the trailing edge, so no row is taller.
    static let rowPitch: CGFloat = 48
    static let rowGap: CGFloat = 2
    /// The list's 6 pt inset, then the row's own 8 pt.
    static let listInset: CGFloat = 6
    static let rowPadding: CGFloat = 8
    static let iconSize: CGFloat = 30
    static let iconToText: CGFloat = 10
    static let buttonSize: CGFloat = 22
}

/// The table's data source and delegate: the rows, the observation that
/// keeps them current, and the rows' actions (menu, double-click, keys, drag).
@MainActor
final class DownloadsTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let downloads: DownloadsController
    let state: DownloadsTableState
    private(set) var rows = DownloadTableRows()
    private(set) var query = ""
    private weak var tableView: DownloadsTableView?
    private var isActive = true
    /// Bumped per observation; only the latest one's change rebuilds.
    private var generation = 0
    private var queryChanged = false
    /// The warnings and review page the cells drew; a change redraws the visible rows.
    private var drawnWarnings: ([String: DownloadWarning], Bool) = ([:], false)
    private var observers: [NSObjectProtocol] = []
    /// Shows the Keep confirmation; tests replace it.
    var confirmKeep: (_ title: String, _ message: String, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void
        = DownloadsTableController.presentKeepAlert

    static let cellID = NSUserInterfaceItemIdentifier("DownloadsTableCell")
    static let rowViewID = NSUserInterfaceItemIdentifier("DownloadsTableRow")

    init(downloads: DownloadsController, state: DownloadsTableState, query: String = "") {
        self.downloads = downloads
        self.state = state
        self.query = query
        super.init()
        state.controller = self
    }

    func makeScrollView() -> NSScrollView {
        let table = DownloadsTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("download"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.rowHeight = DownloadsTableMetrics.rowPitch
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.focusRingType = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsTypeSelect = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked(_:))
        table.controller = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.setAccessibilityLabel("Downloads")
        tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .allowed
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: DownloadsTableMetrics.listInset - DownloadsTableMetrics.rowGap / 2, left: 0,
                                            bottom: DownloadsTableMetrics.listInset - DownloadsTableMetrics.rowGap / 2, right: 0)
        scroll.contentView.postsBoundsChangedNotifications = true
        observers = [
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) {
                [weak table] _ in MainActor.assumeIsolated { table?.syncHover() }
            },
        ]
        rebuild()
        return scroll
    }

    func invalidate() {
        isActive = false
        tableView?.dataSource = nil
        tableView?.delegate = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if state.controller === self { state.controller = nil }
    }

    /// The search changed: the next rebuild filters again and reloads.
    func setQuery(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        queryChanged = true
        rebuild()
    }

    // MARK: Rows

    /// Reads the rows under observation; any change to the list, its
    /// warnings or the review page rebuilds once, on the next main turn.
    private func observedRecords() -> [DownloadRecord] {
        generation += 1
        let current = generation
        return withObservationTracking {
            _ = downloads.warnings
            _ = downloads.canReviewDangerous
            return downloads.matching(query)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.rebuild()
                }
            }
        }
    }

    private func rebuild() {
        guard isActive else { return }
        let reloadAll = queryChanged
        queryChanged = false
        let update = rows.update(to: observedRecords(), reloadAll: reloadAll)
        state.set(isEmpty: rows.count == 0, hasNoDownloads: downloads.records.isEmpty)
        guard let table = tableView else { return }
        // A warning that came or went redraws the rows (their fill, status
        // and buttons). Warnings are rare and only on unfinished rows.
        let warnings = (downloads.warnings, downloads.canReviewDangerous)
        let warningsChanged = warnings != drawnWarnings
        drawnWarnings = warnings
        if update.reloadsAll {
            // `reloadData` threw the cells away and made new ones; with one
            // row height the table only needs the new count, and the visible
            // cells take their new rows in place.
            table.deselectAll(nil)
            table.noteNumberOfRowsChanged()
            if reloadAll { table.scroll(NSPoint(x: 0, y: -(table.enclosingScrollView?.contentInsets.top ?? 0))) }
            reloadVisible(IndexSet(integersIn: 0 ..< rows.count))
            table.syncHover()
            return
        }
        if !update.isEmpty {
            let clip = table.enclosingScrollView?.contentView
            let shift = CGFloat(update.insertedAbove) * DownloadsTableMetrics.rowPitch
            let keepsPlace = shift > 0 && (clip?.bounds.minY ?? 0) > -(clip?.contentInsets.top ?? 0) + 1
            table.beginUpdates()
            if !update.removed.isEmpty { table.removeRows(at: update.removed, withAnimation: []) }
            if !update.inserted.isEmpty { table.insertRows(at: update.inserted, withAnimation: []) }
            table.endUpdates()
            // A new download at the top while the list is scrolled: what was
            // on screen stays there.
            if keepsPlace, let clip {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + shift))
                clip.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
        reloadVisible(warningsChanged ? IndexSet(integersIn: 0 ..< rows.count) : update.reloaded)
        table.syncHover()
    }

    /// Reconfigures the visible cells among `indexes` in place (the table
    /// reloads only rows it has views for).
    private func reloadVisible(_ indexes: IndexSet) {
        guard let table = tableView, !indexes.isEmpty else { return }
        let visible = table.rows(in: table.visibleRect)
        for row in indexes where row >= visible.location && row < visible.location + visible.length {
            guard rows.records.indices.contains(row),
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? DownloadsTableCell else { continue }
            cell.configure(rows.records[row], controller: self)
            (table.rowView(atRow: row, makeIfNecessary: false) as? DownloadsTableRowView)?.isWarned = isWarned(rows.records[row])
        }
    }

    func record(at row: Int) -> DownloadRecord? {
        rows.records.indices.contains(row) ? rows.records[row] : nil
    }

    func isWarned(_ record: DownloadRecord) -> Bool { downloads.needsDecision(record) }

    // MARK: Focus

    /// The search field's ↓: the list takes the keyboard on its first row.
    func focusList() {
        guard let table = tableView, let window = table.window, rows.count > 0 else { return }
        window.makeFirstResponder(table)
        if table.selectedRowIndexes.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        table.scrollRowToVisible(table.selectedRow)
    }

    // MARK: Actions

    func perform(_ action: DownloadAction, on ids: [String]) {
        for id in ids { downloads.perform(action, on: id) }
    }

    @objc func openClicked(_ sender: Any?) {
        guard let table = tableView, let record = record(at: table.clickedRow), record.hasFileOnDisk else { return }
        downloads.perform(.open, on: record.id)
    }

    /// The rows a menu or key acts on (`DownloadTableRows.targets`).
    private func targets(clicked: Int) -> [DownloadRecord] {
        guard let table = tableView else { return [] }
        return DownloadTableRows.targets(clicked: clicked, selected: table.selectedRowIndexes, count: rows.count).compactMap(record(at:))
    }

    /// Return: open the selected files.
    func openSelection() {
        for record in targets(clicked: -1) where record.hasFileOnDisk { downloads.perform(.open, on: record.id) }
    }

    /// Delete: remove the selected rows from the list.
    func removeSelection() {
        perform(.remove, on: targets(clicked: -1).map(\.id))
    }

    /// ⌘C: the selected rows' download links, one a line.
    func copySelection() {
        copyLinks(targets(clicked: -1))
    }

    private func copyLinks(_ records: [DownloadRecord]) {
        guard !records.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(records.map(\.url).joined(separator: "\n"), forType: .string)
    }

    var hasSelection: Bool { !(tableView?.selectedRowIndexes.isEmpty ?? true) }

    func keep(_ record: DownloadRecord, from view: NSView) {
        let message = "\(downloads.warningText(for: record) ?? "This file may be harmful"). Only keep it if you trust its source."
        confirmKeep("Keep \(record.fileName)?", message, view.window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.downloads.keep(record.id)
            case .alertSecondButtonReturn: self.downloads.discard(record.id)
            default: break
            }
        }
    }

    /// `DownloadRowView`'s confirmation: Keep Anyway, Discard or Cancel.
    private static func presentKeepAlert(_ title: String, _ message: String, window: NSWindow?,
                                         done: @escaping (NSApplication.ModalResponse) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Anyway").hasDestructiveAction = true
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        if let window {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table = tableView, table.clickedRow >= 0 else { return }
        let records = targets(clicked: table.clickedRow)
        guard !records.isEmpty else { return }
        for item in menuItems(for: records) { menu.addItem(item) }
    }

    /// The row's menu, as `DownloadRowView`'s; several rows get the actions that apply to each.
    func menuItems(for records: [DownloadRecord]) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = DownloadsMenuItem(title: title, action: action)
            item.isEnabled = enabled
            items.append(item)
        }
        let withFiles = records.filter(\.hasFileOnDisk)
        if !withFiles.isEmpty {
            add("Open") { [weak self] in self?.perform(.open, on: withFiles.map(\.id)) }
            add("Show in Finder") { [weak self] in self?.perform(.reveal, on: withFiles.map(\.id)) }
            items.append(.separator())
        }
        if records.count == 1, let record = records.first, record.isActive {
            if record.isPaused {
                add("Resume", enabled: record.canResume) { [weak self] in self?.perform(.resume, on: [record.id]) }
            } else if !isWarned(record) {
                add("Pause") { [weak self] in self?.perform(.pause, on: [record.id]) }
            }
            add("Cancel") { [weak self] in self?.perform(.cancel, on: [record.id]) }
            items.append(.separator())
        }
        add(records.count == 1 ? "Copy Download Link" : "Copy Download Links") { [weak self] in self?.copyLinks(records) }
        add("Remove from List") { [weak self] in self?.perform(.remove, on: records.map(\.id)) }
        return items
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? DownloadsTableRowView ?? {
            let view = DownloadsTableRowView()
            view.identifier = Self.rowViewID
            return view
        }()
        view.isWarned = record(at: row).map(isWarned) ?? false
        view.isHovered = row == self.tableView?.hoveredRow
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let record = record(at: row) else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? DownloadsTableCell ?? {
            let cell = DownloadsTableCell()
            cell.identifier = Self.cellID
            return cell
        }()
        cell.configure(record, controller: self)
        cell.isHovered = row == self.tableView?.hoveredRow
        return cell
    }

    /// Files drag out to Finder and other apps as file URLs.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let record = record(at: row), record.hasFileOnDisk else { return nil }
        return URL(fileURLWithPath: record.targetPath) as NSURL
    }
}

/// A menu item that runs a closure.
private final class DownloadsMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { run() }
}

/// The table: keyboard actions for the selection, and the row under the
/// pointer from one tracking area. AppKit's tracking ignores a hidden cursor,
/// which SwiftUI's hover does not.
final class DownloadsTableView: NSTableView {
    weak var controller: DownloadsTableController?
    private(set) var hoveredRow = -1
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHovered(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHovered(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(-1)
    }

    /// After a scroll or a reload the rows moved under a still pointer.
    func syncHover() {
        guard let window else { return setHovered(-1) }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(visibleRect.contains(point) ? row(at: point) : -1)
    }

    private func setHovered(_ row: Int) {
        guard row != hoveredRow else { return }
        let old = hoveredRow
        hoveredRow = row
        for index in [old, row] where index >= 0 && index < numberOfRows {
            (rowView(atRow: index, makeIfNecessary: false) as? DownloadsTableRowView)?.isHovered = index == row
            (view(atColumn: 0, row: index, makeIfNecessary: false) as? DownloadsTableCell)?.isHovered = index == row
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Return or Enter opens; Delete, Forward Delete or ⌘⌫ removes.
        if [36, 76].contains(event.keyCode), modifiers.isEmpty {
            controller?.openSelection()
        } else if [51, 117].contains(event.keyCode), modifiers.isEmpty || modifiers == .command {
            controller?.removeSelection()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Accessibility

    /// Accessibility sees the rows on screen, as it saw the SwiftUI list's
    /// built rows. By default a table reports every row: an Accessibility
    /// client walking the tree (VoiceOver, window managers) made AppKit
    /// create an element for each of 39k rows, ~1 s of main thread a walk.
    /// Arrow keys move the selection and scroll, which brings rows in.
    var visibleRowViews: [NSTableRowView] {
        let range = rows(in: visibleRect)
        guard range.length > 0 else { return [] }
        return (range.location ..< range.location + range.length).compactMap { rowView(atRow: $0, makeIfNecessary: false) }
    }

    override func accessibilityChildren() -> [Any]? { visibleRowViews }
    override func accessibilityRows() -> [NSAccessibilityRow]? { visibleRowViews }
    override func accessibilityVisibleRows() -> [NSAccessibilityRow]? { visibleRowViews }
    override func accessibilitySelectedRows() -> [NSAccessibilityRow]? { visibleRowViews.filter(\.isSelected) }

    @objc func copy(_ sender: Any?) {
        controller?.copySelection()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return controller?.hasSelection ?? false }
        return super.validateUserInterfaceItem(item)
    }
}

/// A row's fill: the hover wash, the selection, or a warned row's orange,
/// on a continuous 8 pt rounded rectangle inset to the list's margins.
final class DownloadsTableRowView: NSTableRowView {
    var isHovered = false { didSet { if isHovered != oldValue { updateFill() } } }
    var isWarned = false { didSet { if isWarned != oldValue { updateFill() } } }
    private let fill = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fill.cornerRadius = 8
        fill.cornerCurve = .continuous
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isSelected: Bool { didSet { if isSelected != oldValue { updateFill() } } }
    override var isEmphasized: Bool { didSet { if isEmphasized != oldValue { updateFill() } } }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds.insetBy(dx: DownloadsTableMetrics.listInset, dy: DownloadsTableMetrics.rowGap / 2)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        var color: NSColor?
        if isSelected {
            color = isEmphasized ? NSColor.controlAccentColor.withAlphaComponent(0.22) : NSColor.labelColor.withAlphaComponent(0.1)
        } else if isWarned {
            color = NSColor.systemOrange.withAlphaComponent(0.1)
        } else if isHovered {
            color = NSColor.labelColor.withAlphaComponent(0.06)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance { fill.backgroundColor = color?.cgColor }
        CATransaction.commit()
    }
}
