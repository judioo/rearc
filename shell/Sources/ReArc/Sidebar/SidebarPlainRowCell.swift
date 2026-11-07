import AppKit
import CoreImage
import SwiftUI
import SidebarModel

/// A tab or folder row drawn with plain AppKit views (perf-7).
///
/// A hosting view per visible row cost a full SwiftUI render on every scroll
/// frame: SwiftUI observes each hosting view's position in the window and
/// its safe area, so all ~22 visible cells re-rendered whenever the list
/// moved, whatever they contained (perf-6). Layers that only move cost
/// nothing to scroll.
///
/// The row's behaviour stays in SwiftUI. While the pointer is over the row,
/// a drag is under way, or the row shows something rare (a loading ring, an
/// audio or Picture in Picture badge), the cell hosts the same
/// `SidebarEntryRow` as before over its plain drawing, so clicks, the hover
/// close button, context menus, drag and drop and tooltips are the SwiftUI
/// row's own. Only one or two rows are hosted at a time.
final class SidebarPlainRowCell: NSView {
    private(set) var rowID: UUID?
    private var kind: SidebarOutlineNode.Kind = .tab
    private var depth = 0
    private weak var controller: SidebarListController?
    private var generation = 0

    private var state = PlainRowState()
    private var pointerInside = false
    /// The hosted SwiftUI row reports its own hover; until it does, the plain
    /// hover fill stays under it.
    private var hostedHover = false
    private var hosting: SidebarCountingHostingView<SidebarHostedRow>?
    private var keepAliveTimer: Timer?

    private let fill = SidebarRowFillView()
    private let icon = NSImageView()
    private let tokenBadge = NSView()
    private let token = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let unread = CALayer()
    private let content = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        content.wantsLayer = true
        addSubview(fill)
        addSubview(content)

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageAlignment = .alignCenter
        icon.wantsLayer = true
        icon.layer?.masksToBounds = true
        icon.layerUsesCoreImageFilters = true
        content.addSubview(icon)

        token.alignment = .center
        tokenBadge.wantsLayer = true
        tokenBadge.layer?.cornerCurve = .continuous
        tokenBadge.addSubview(token)
        content.addSubview(tokenBadge)

        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.cell?.usesSingleLineMode = true
        title.cell?.truncatesLastVisibleLine = true
        content.addSubview(title)

        unread.cornerRadius = 3
        content.layer?.addSublayer(unread)

        for view in [fill, content, icon, tokenBadge, token, title] as [NSView] { view.setAccessibilityElement(false) }
        registerForDraggedTypes([.string, .URL, .fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    // MARK: Configuration

    /// Hands the cell a row. A reused cell drops the last row's hosted view.
    func configure(row: SidebarOutlineRow, controller: SidebarListController) {
        if row.id != rowID {
            unhost()
            if pointerInside, let rowID { controller.hoverPreview.pointerExited(rowID) }
            pointerInside = false
        }
        rowID = row.id
        kind = row.node.kind
        depth = row.depth
        self.controller = controller
        if let hosting, let root = controller.hostedRoot(for: row.id, cell: self) { hosting.rootView = root }
        needsLayout = true
        refresh()
    }

    /// Reads the row's state under observation; a change reads it again on
    /// the next turn of the main queue.
    func refresh() {
        guard let controller, let rowID else { return }
        generation += 1
        let current = generation
        let model = controller.model, spaceID = controller.spaceID, context = controller.context
        let next = withObservationTracking {
            PlainRowState.read(id: rowID, model: model, spaceID: spaceID, chrome: context.chrome)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.refresh()
            }
        }
        let changed = next != state
        state = next
        if changed { apply() }
        updateHosting()
    }

    private func apply() {
        let chrome = state.chrome
        effectiveAppearance.performAsCurrentDrawingAppearance {
            title.font = .systemFont(ofSize: SidebarMetrics.titleSize, weight: kind == .folder ? .semibold : .regular)
            title.stringValue = state.title
            title.textColor = NSColor(chrome.title)
            if let customIcon = state.customIcon {
                applyCustomIcon(customIcon)
            } else {
                switch kind {
                case .folder:
                    let symbol = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
                    icon.image = symbol
                    icon.imageScaling = .scaleNone
                    icon.contentTintColor = NSColor(chrome.accent)
                    icon.layer?.cornerRadius = 0
                    icon.isHidden = false
                    icon.alphaValue = 1
                    icon.contentFilters = []
                    tokenBadge.isHidden = true
                default:
                    icon.imageScaling = .scaleProportionallyUpOrDown
                    icon.contentTintColor = nil
                    icon.layer?.cornerRadius = SidebarMetrics.iconSize * 0.2
                    if let favicon = state.favicon {
                        icon.image = favicon
                        icon.isHidden = false
                        tokenBadge.isHidden = true
                    } else {
                        icon.image = nil
                        icon.isHidden = true
                        tokenBadge.isHidden = false
                        token.stringValue = state.token
                        token.font = .systemFont(ofSize: SidebarMetrics.iconSize * 0.6, weight: .bold)
                        token.textColor = NSColor(chrome.title)
                        tokenBadge.layer?.cornerRadius = SidebarMetrics.iconSize * 0.3
                        tokenBadge.layer?.backgroundColor = NSColor(chrome.title).withAlphaComponent(0.08).cgColor
                    }
                    let dim = state.isUnloaded
                    icon.alphaValue = dim ? 0.4 : 1
                    tokenBadge.alphaValue = dim ? 0.4 : 1
                    icon.contentFilters = dim ? Self.grayscale : []
                }
            }
            unread.backgroundColor = NSColor.controlAccentColor.cgColor
            unread.isHidden = !state.isUnread
            fill.selectedColor = NSColor(chrome.rowSelected).cgColor
            fill.hoverColor = NSColor(chrome.rowHover).cgColor
            fill.shadowOpacity = chrome.isDark ? 0.3 : 0.08
        }
        updateFill()
        needsLayout = true
    }

    private func applyCustomIcon(_ customIcon: SidebarItemIcon) {
        let size = kind == .folder ? 17 : SidebarMetrics.iconSize
        icon.layer?.cornerRadius = 0
        icon.contentFilters = state.isUnloaded ? Self.grayscale : []
        icon.alphaValue = state.isUnloaded ? 0.4 : 1
        tokenBadge.alphaValue = icon.alphaValue
        switch customIcon {
        case .sfSymbol(let name):
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.contentTintColor = NSColor(kind == .folder ? state.chrome.accent : state.chrome.title)
            icon.isHidden = false
            tokenBadge.isHidden = true
        case .emoji(let text):
            icon.isHidden = true
            tokenBadge.isHidden = false
            token.stringValue = text
            token.font = .systemFont(ofSize: size)
            token.textColor = NSColor(state.chrome.title)
            tokenBadge.layer?.backgroundColor = nil
        }
    }

    private static let grayscale: [CIFilter] = {
        guard let filter = CIFilter(name: "CIColorControls") else { return [] }
        filter.setDefaults()
        filter.setValue(0, forKey: kCIInputSaturationKey)
        return [filter]
    }()

    // MARK: Layout

    /// `TabRowView` and `FolderRowView`'s geometry: the 8 pt row inset, 14 pt
    /// per folder level, a 36 pt highlight centred in the 41 pt pitch, the
    /// icon 10 pt in, the title 11 pt after it.
    override func layout() {
        super.layout()
        let width = bounds.width
        let x0 = SidebarMetrics.rowInset + CGFloat(depth) * 14
        let inset = (SidebarMetrics.rowPitch - SidebarMetrics.rowHeight) / 2
        let highlight = NSRect(x: x0, y: inset, width: max(0, width - SidebarMetrics.rowInset - x0), height: SidebarMetrics.rowHeight)
        fill.frame = highlight
        content.frame = bounds
        hosting?.frame = bounds
        let midY = highlight.midY
        let iconX = x0 + SidebarMetrics.iconLeading
        let size = SidebarMetrics.iconSize
        if kind == .folder {
            icon.frame = NSRect(x: iconX - 1.5, y: midY - (size + 3) / 2, width: size + 3, height: size + 3)
        } else {
            icon.frame = NSRect(x: iconX, y: midY - size / 2, width: size, height: size)
            tokenBadge.frame = NSRect(x: iconX - 1, y: midY - (size + 2) / 2, width: size + 2, height: size + 2)
            let letter = token.intrinsicContentSize
            token.frame = NSRect(x: 0, y: ((size + 2 - letter.height) / 2).rounded(), width: size + 2, height: ceil(letter.height))
        }
        let titleX = iconX + size + SidebarMetrics.iconToText
        let trailing = highlight.maxX - 8
        let dot: CGFloat = state.isUnread ? 6 + SidebarMetrics.iconToText : 0
        // The cell measures the current font and string; the field's cached
        // intrinsic size could still be the default 13 pt font's and cut titles short.
        let natural = ceil(title.cell?.cellSize.width ?? title.intrinsicContentSize.width)
        let titleWidth = max(0, min(natural, trailing - titleX - dot))
        let titleHeight = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: titleX, y: (midY - titleHeight / 2).rounded(), width: titleWidth, height: titleHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        unread.frame = CGRect(x: titleX + titleWidth + SidebarMetrics.iconToText, y: midY - 3, width: 6, height: 6)
        CATransaction.commit()
    }

    // MARK: Hosting the SwiftUI row

    /// Whether the SwiftUI row should be live over the plain one.
    private var wantsHosting: Bool {
        guard let controller, rowID != nil else { return false }
        if controller.hostsAllRows || state.needsHosting { return true }
        if pointerInside, !controller.isLiveScrolling { return true }
        // Keep a row live while it owns the interaction: a menu open from it,
        // or the button still down from a press that began on it.
        if hosting != nil, controller.isMenuTracking || NSEvent.pressedMouseButtons != 0 { return true }
        return false
    }

    func updateHosting() {
        if wantsHosting {
            host()
        } else {
            unhost()
        }
        updateKeepAlive()
    }

    private func host() {
        guard hosting == nil, let controller, let rowID else { return }
        guard let root = controller.hostedRoot(for: rowID, cell: self) else { return }
        let view = SidebarCountingHostingView(rootView: root)
        view.sizingOptions = []
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        hostedHover = false
        addSubview(view)
        hosting = view
        SidebarListCellCounters.hostings += 1
        // Render the SwiftUI row now so it lands in the same commit that
        // hides the plain drawing: no blank frame and no doubled fill.
        view.layoutSubtreeIfNeeded()
        content.isHidden = true
        updateFill()
        setAccessibilityElement(false)
    }

    private func unhost() {
        guard let view = hosting else { return }
        content.isHidden = false
        hosting = nil
        hostedHover = false
        view.removeFromSuperview()
        updateFill()
        setAccessibilityElement(true)
    }

    /// While the pointer, a held button or an open menu keeps the row live,
    /// check again until none does. The pointer is read, not only waited
    /// for: a move that leaves within a few milliseconds of the one that
    /// entered can lose its exit, and the row stayed hosted and hovered with
    /// the pointer gone (Break check 2026-11-08).
    private func updateKeepAlive() {
        let needed = hosting != nil && controller?.hostsAllRows != true && !state.needsHosting
        if needed, keepAliveTimer == nil {
            keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.recheckPointer() }
            }
        } else if !needed {
            keepAliveTimer?.invalidate()
            keepAliveTimer = nil
        }
    }

    /// From the hosted row's own hover.
    func hostedHoverChanged(_ hovering: Bool) {
        hostedHover = hovering
        updateFill()
    }

    private func updateFill() {
        let hosted = hosting != nil
        let style: SidebarRowFillView.Style
        if !hosted, state.isSelected, kind != .folder {
            style = .selected
        } else if pointerInside, !(hosted && hostedHover), !(hosted && state.isSelected && kind != .folder) {
            style = .hover
        } else {
            style = .none
        }
        fill.style = style
    }

    // MARK: Pointer

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Hosting the SwiftUI row on entry rebuilds the area with the pointer
        // inside. Without assumeInside a new area sends no exit until a move
        // lands inside it, so a pointer flicked out at once left the row
        // hosted and hovered.
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
        if pointerInside { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        updateFill()
        updateHosting()
        if let rowID { controller?.hoverPreview.pointerEntered(self, id: rowID, kind: kind) }
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        updateFill()
        updateHosting()
        if let rowID { controller?.hoverPreview.pointerExited(rowID) }
    }

    /// Re-reads whether the pointer is over the row, after a scroll or a
    /// menu that may have hidden the enter and exit events.
    func syncPointer() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = bounds.contains(point) && visibleRect.contains(point)
        if inside != pointerInside {
            pointerInside = inside
            updateFill()
        }
        updateHosting()
    }

    /// `syncPointer`, and an exit it finds ends the row's hover preview too.
    private func recheckPointer() {
        let wasInside = pointerInside
        syncPointer()
        if wasInside, !pointerInside, let rowID { controller?.hoverPreview.pointerExited(rowID) }
    }

    /// A press that reaches the plain row (the pointer arrived without an
    /// enter event): host the SwiftUI row and give it the event.
    override func mouseDown(with event: NSEvent) { forward(event) }
    override func rightMouseDown(with event: NSEvent) { forward(event) }
    override func otherMouseDown(with event: NSEvent) { forward(event) }

    private var forwarding = false

    private func forward(_ event: NSEvent) {
        guard !forwarding else { return }
        pointerInside = true
        host()
        guard hosting != nil, let window else { return }
        forwarding = true
        window.sendEvent(event)
        forwarding = false
        updateKeepAlive()
    }

    // MARK: Links dragged in from pages and other apps

    /// A drag that reaches a plain row makes every visible row live, so the
    /// SwiftUI rows' drop targets take the drag from the next move on.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.noteExternalDrag()
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.noteExternalDrag()
        return []
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { hosting == nil && rowID != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        state.isUnread ? "\(state.title), Unread" : state.title
    }
    override func accessibilityValue() -> Any? {
        kind == .folder ? (state.isExpanded ? "expanded" : "collapsed") : nil
    }
    override func isAccessibilitySelected() -> Bool { state.isSelected }
    override func accessibilityPerformPress() -> Bool {
        guard let controller, let rowID else { return false }
        controller.press(rowID, kind: kind)
        return true
    }
}

/// What a plain row draws, read from the model under observation.
struct PlainRowState: Equatable {
    var title = ""
    var favicon: NSImage?
    var customIcon: SidebarItemIcon?
    var token = ""
    var isSelected = false
    var isUnloaded = false
    var isUnread = false
    var isExpanded = false
    /// Something only the SwiftUI row draws (a loading ring, a crash glyph,
    /// an audio or Picture in Picture badge, the rename hint), or a rename
    /// field that keeps focus wherever the pointer goes.
    var needsHosting = false
    var chrome = ThemeChromeColors(theme: .default, dark: false)

    static func read(id: UUID, model: BrowserViewModel, spaceID: Space.ID, chrome: ThemeChromeColors) -> PlainRowState {
        var state = PlainRowState()
        state.chrome = chrome
        switch model.store.entry(withID: id) {
        case .tab(let tab):
            state.title = tab.displayTitle
            state.customIcon = tab.customIcon
            state.favicon = model.favicon(for: tab)
            state.token = tab.faviconToken
            state.isSelected = model.store.isSelected(tab.id, inSpace: spaceID)
            state.isUnloaded = model.isTabUnloaded(tab.id)
            state.isUnread = tab.isUnread
            state.needsHosting = model.tabActivity(tab.id) != .idle
                || model.showsAudibleIndicator(for: tab.id)
                || model.isPictureInPicture(tab.id)
                || model.renameHint?.tabID == tab.id
                || model.inlineRename(forRow: tab.id) != nil
                || model.itemIconEditorID == tab.id
        case .folder(let folder):
            state.title = folder.title
            state.customIcon = folder.customIcon
            state.isExpanded = model.store.isFolderExpanded(folder.id)
            state.needsHosting = model.inlineRename(forRow: folder.id) != nil || model.itemIconEditorID == folder.id
        case .split, .easel, nil:
            // Not a row the plain cell draws: the SwiftUI row takes over.
            state.needsHosting = true
        }
        return state
    }

    static func == (a: PlainRowState, b: PlainRowState) -> Bool {
        a.title == b.title && a.customIcon == b.customIcon && a.favicon === b.favicon && a.token == b.token && a.isSelected == b.isSelected
            && a.isUnloaded == b.isUnloaded && a.isUnread == b.isUnread && a.isExpanded == b.isExpanded
            && a.needsHosting == b.needsHosting && a.chrome == b.chrome
    }
}

/// The row's highlight: the selected fill with its small shadow, or the
/// hover wash, on a continuous 8 pt rounded rectangle.
final class SidebarRowFillView: NSView {
    enum Style { case none, hover, selected }

    var style: Style = .none { didSet { if style != oldValue { needsDisplay = true } } }
    var selectedColor: CGColor? { didSet { needsDisplay = true } }
    var hoverColor: CGColor? { didSet { needsDisplay = true } }
    var shadowOpacity: Float = 0.08 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        switch style {
        case .none:
            layer.backgroundColor = nil
            layer.shadowOpacity = 0
        case .hover:
            layer.backgroundColor = hoverColor
            layer.shadowOpacity = 0
        case .selected:
            layer.backgroundColor = selectedColor
            layer.shadowColor = .black
            layer.shadowOpacity = shadowOpacity
            layer.shadowRadius = 1.5
            layer.shadowOffset = CGSize(width: 0, height: -0.5)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The hosted SwiftUI row of a plain cell: the usual cell root, reporting
/// its hover back so the plain hover fill steps aside.
struct SidebarHostedRow: View {
    let cell: SidebarListCell
    let onHover: (Bool) -> Void

    var body: some View {
        cell.onHover(perform: onHover)
    }
}

/// A hosting view counted by the bench (perf-6): how often cells lay out.
final class SidebarCountingHostingView<Content: View>: NSHostingView<Content> {
    override func layout() {
        SidebarListCellCounters.layouts += 1
        super.layout()
    }
}
