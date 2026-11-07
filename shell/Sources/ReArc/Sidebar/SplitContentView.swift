import SwiftUI
import SidebarModel

/// Renders 2–4 web panes with draggable dividers for an active split
/// selection, or the expanded pane alone (Expand Current Split). As in Arc
/// each pane is its own rounded card, 10 pt apart, with its own toolbar row
/// when "URL in toolbar" is on (SPLIT-VIEW §3.1); the focused card has an
/// accent ring. In HTML fullscreen the same views lose rows, gaps and corners.
struct SplitContentView: View {
    let split: SplitViewItem
    let model: BrowserViewModel
    let accent: Color
    /// "URL in toolbar" on and not in HTML fullscreen.
    var showsRows = false
    /// Separate cards (off in HTML fullscreen: the page edge to edge).
    var showsCards = false
    var cardFill: Color = .clear
    /// The top-left row clears the traffic lights with the sidebar on the right.
    var trafficLightsClearance: CGFloat = 0
    @Environment(\.sidebarWindow) private var window

    @State private var liveFactors: [Tab.ID: Double] = [:]
    @State private var dragStartFactors: [Tab.ID: Double] = [:]
    @State private var isDraggingDivider = false

    var body: some View {
        GeometryReader { proxy in
            let ordered = split.tabs
            let factors = normalizedFactors(for: ordered)
            let layout = model.splitPaneToolbarLayout(split, in: window)
            if let expanded = model.expandedSplitPane(split, in: window),
               let tab = ordered.first(where: { $0.id == expanded }) {
                pane(for: tab, row: layout.row(for: tab.id), ringed: false)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .overlay(alignment: .top) {
                        restorePill.padding(.top, showsRows ? CardToolbarView.height : 0)
                    }
            } else if split.orientation == .horizontal {
                horizontalLayout(size: proxy.size, tabs: ordered, factors: factors, layout: layout)
            } else {
                verticalLayout(size: proxy.size, tabs: ordered, factors: factors, layout: layout)
            }
        }
        .onAppear { liveFactors = split.widthFactors }
        .onChange(of: split.widthFactors) { _, new in
            if !isDraggingDivider { liveFactors = new }
        }
    }

    /// The other panes stay open behind the expanded one.
    private var restorePill: some View {
        Button {
            model.toggleExpandedSplitPane(split.id, in: window)
        } label: {
            Label("Show Split View (\(split.tabs.count) panes)", systemImage: split.orientation == .horizontal
                  ? "rectangle.split.2x1" : "rectangle.split.1x2")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .help("Expand Current Split is on — click to show every pane again")
    }

    /// The gap between panes: the window background between two cards, or a
    /// thin rule edge to edge.
    private var dividerThickness: CGFloat { showsCards ? BrowserView.cardInset : 5 }

    @ViewBuilder
    private func horizontalLayout(size: CGSize, tabs: [Tab], factors: [Double], layout: SplitPaneToolbarLayout) -> some View {
        let space = paneSpace(size.width, count: tabs.count)
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                pane(for: tab, row: layout.row(for: tab.id), ringed: true)
                    .frame(width: max(120, space * factors[index]))
                if index < tabs.count - 1 {
                    divider(axis: .vertical, beforeIndex: index + 1, tabs: tabs, total: space)
                }
            }
        }
    }

    @ViewBuilder
    private func verticalLayout(size: CGSize, tabs: [Tab], factors: [Double], layout: SplitPaneToolbarLayout) -> some View {
        let space = paneSpace(size.height, count: tabs.count)
        VStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                pane(for: tab, row: layout.row(for: tab.id), ringed: true)
                    .frame(height: max(120, space * factors[index]))
                if index < tabs.count - 1 {
                    divider(axis: .horizontal, beforeIndex: index + 1, tabs: tabs, total: space)
                }
            }
        }
    }

    /// The length the panes share once the dividers are taken out.
    private func paneSpace(_ length: CGFloat, count: Int) -> CGFloat {
        max(length - dividerThickness * CGFloat(max(count - 1, 0)), 1)
    }

    @ViewBuilder
    private func pane(for tab: Tab, row: SplitPaneToolbarLayout.Row?, ringed: Bool) -> some View {
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        let radius: CGFloat = showsCards ? BrowserView.cardRadius : 0
        let card = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let focused = ringed && row?.isActive == true
        VStack(spacing: 0) {
            if showsRows, let row {
                SplitPaneToolbarView(
                    model: model, splitID: split.id, orientation: split.orientation, tab: tab, engine: engine, row: row,
                    trafficLightsClearance: trafficLightsClearance
                )
                .equatable()
                .zIndex(1)
            }
            SplitPanePage(engine: engine, tabID: tab.id, findBar: model.findBar)
        }
        .clipShape(card)
        .background(card.fill(showsCards ? cardFill : .clear))
        .background(PaneCardShadow(radius: radius).opacity(showsCards ? 1 : 0))
        .overlay(
            card.strokeBorder(focused ? accent.opacity(showsCards ? 0.8 : 0.45) : .clear, lineWidth: showsCards ? 1.5 : 2)
                .allowsHitTesting(false)
        )
        .background(PaneClickMonitor { model.focusSplitPane(tab.id, in: split.id) })
    }

    @ViewBuilder
    private func divider(axis: Axis, beforeIndex: Int, tabs: [Tab], total: CGFloat) -> some View {
        SplitDividerHandle(axis: axis, thickness: dividerThickness, isGap: showsCards)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDraggingDivider {
                            let ids = tabs.map(\.id)
                            dragStartFactors = SplitViewItem.normalizedFactors(
                                liveFactors.isEmpty ? split.widthFactors : liveFactors,
                                tabIDs: ids
                            )
                        }
                        isDraggingDivider = true
                        adjustFactors(
                            beforeIndex: beforeIndex,
                            delta: axis == .horizontal ? value.translation.height : value.translation.width,
                            total: total,
                            tabs: tabs,
                            startMap: dragStartFactors
                        )
                    }
                    .onEnded { _ in
                        isDraggingDivider = false
                        dragStartFactors = [:]
                        model.store.resizeSplitPanes(splitID: split.id, widthFactors: liveFactors)
                    }
            )
    }

    private func normalizedFactors(for tabs: [Tab]) -> [Double] {
        let ids = tabs.map(\.id)
        let map = SplitViewItem.normalizedFactors(liveFactors.isEmpty ? split.widthFactors : liveFactors, tabIDs: ids)
        return ids.map { map[$0] ?? (1.0 / Double(ids.count)) }
    }

    private func adjustFactors(
        beforeIndex: Int,
        delta: CGFloat,
        total: CGFloat,
        tabs: [Tab],
        startMap: [Tab.ID: Double]
    ) {
        guard beforeIndex > 0, beforeIndex < tabs.count else { return }
        let left = tabs[beforeIndex - 1].id
        let right = tabs[beforeIndex].id
        let ids = tabs.map(\.id)
        var map = SplitViewItem.normalizedFactors(startMap, tabIDs: ids)
        let shift = Double(delta / max(total, 1))
        var leftFactor = (map[left] ?? 0) + shift
        var rightFactor = (map[right] ?? 0) - shift
        let minPane = 0.12
        if leftFactor < minPane {
            rightFactor -= (minPane - leftFactor)
            leftFactor = minPane
        }
        if rightFactor < minPane {
            leftFactor -= (minPane - rightFactor)
            rightFactor = minPane
        }
        map[left] = leftFactor
        map[right] = rightFactor
        liveFactors = SplitViewItem.normalizedFactors(map, tabIDs: ids)
    }
}

/// Between cards: the window background with Arc's grip in the middle
/// (2.5 × 24 pt). Edge to edge: a thin rule.
private struct SplitDividerHandle: View {
    let axis: Axis
    var thickness: CGFloat = 5
    var isGap = false
    @State private var isHovering = false
    @State private var cursorPushed = false

    var body: some View {
        ZStack {
            if isGap {
                Color.clear
                Capsule()
                    .fill(Color.primary.opacity(isHovering ? 0.3 : 0.16))
                    .frame(width: axis == .vertical ? 2.5 : 24, height: axis == .vertical ? 24 : 2.5)
            } else {
                Rectangle().fill(isHovering ? Color.primary.opacity(0.25) : Color.primary.opacity(0.12))
            }
        }
        .frame(
            width: axis == .vertical ? thickness : nil,
            height: axis == .horizontal ? thickness : nil
        )
        .frame(maxWidth: axis == .horizontal ? .infinity : nil, maxHeight: axis == .vertical ? .infinity : nil)
        .contentShape(Rectangle().inset(by: isGap ? 0 : -4))
        .onHover { hovering in
            isHovering = hovering
            let cursor = axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown
            if hovering, !cursorPushed {
                cursor.push()
                cursorPushed = true
            } else if !hovering, cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
    }
}

/// One pane's page. Its load progress is read here, so a pane loading
/// re-renders only its own page, not the split or the other panes.
private struct SplitPanePage: View {
    let engine: any WebEngine
    let tabID: Tab.ID
    let findBar: FindBarModel

    var body: some View {
        engine.makeView()
            .id(tabID)
            .pageStatus(engine.activity) { engine.reload() }
            .findBar(findBar, for: engine)
    }
}

/// A pane card's shadow outside its shape (BrowserView's card shadow), seen
/// in the gap between cards; the outer card's own shadow draws the rest.
private struct PaneCardShadow: View {
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(Color.black)
            .shadow(color: .black.opacity(0.22), radius: 3, x: 0, y: 1.25)
            .mask {
                Rectangle()
                    .padding(-24)
                    .overlay { shape.blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

/// Reports a click anywhere in its frame, the page included: Chromium's and
/// WebKit's views take the mouse, so a tap gesture over them never fires.
/// The event is passed on untouched.
private struct PaneClickMonitor: NSViewRepresentable {
    var onClick: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(frame: .zero)
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onClick = onClick
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onClick: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            onClick?()
        }
    }
}
