import SwiftUI
import SidebarModel

/// Renders 2–4 web panes with draggable dividers for an active split selection.
struct SplitContentView: View {
    let split: SplitViewItem
    let model: BrowserViewModel
    let accent: Color

    @State private var liveFactors: [Tab.ID: Double] = [:]
    @State private var dragStartFactors: [Tab.ID: Double] = [:]
    @State private var isDraggingDivider = false

    var body: some View {
        GeometryReader { proxy in
            let ordered = split.tabs
            let factors = normalizedFactors(for: ordered)
            if split.orientation == .horizontal {
                horizontalLayout(size: proxy.size, tabs: ordered, factors: factors)
            } else {
                verticalLayout(size: proxy.size, tabs: ordered, factors: factors)
            }
        }
        .onAppear { liveFactors = split.widthFactors }
        .onChange(of: split.widthFactors) { _, new in
            if !isDraggingDivider { liveFactors = new }
        }
    }

    @ViewBuilder
    private func horizontalLayout(size: CGSize, tabs: [Tab], factors: [Double]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                pane(for: tab, focused: split.focusTabID == tab.id)
                    .frame(width: max(120, size.width * factors[index]))
                if index < tabs.count - 1 {
                    divider(axis: .vertical, beforeIndex: index + 1, tabs: tabs, total: size.width)
                }
            }
        }
    }

    @ViewBuilder
    private func verticalLayout(size: CGSize, tabs: [Tab], factors: [Double]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                pane(for: tab, focused: split.focusTabID == tab.id)
                    .frame(height: max(120, size.height * factors[index]))
                if index < tabs.count - 1 {
                    divider(axis: .horizontal, beforeIndex: index + 1, tabs: tabs, total: size.height)
                }
            }
        }
    }

    @ViewBuilder
    private func pane(for tab: Tab, focused: Bool) -> some View {
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        engine.makeView()
            .id(tab.id)
            .findBar(model.findBar, for: engine)
            .overlay(
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(focused ? accent.opacity(0.45) : .clear, lineWidth: 2)
            )
            .onTapGesture { model.selectSplit(split.id, focusTabID: tab.id) }
    }

    @ViewBuilder
    private func divider(axis: Axis, beforeIndex: Int, tabs: [Tab], total: CGFloat) -> some View {
        SplitDividerHandle(axis: axis)
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

private struct SplitDividerHandle: View {
    let axis: Axis
    @State private var isHovering = false
    @State private var cursorPushed = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.primary.opacity(0.25) : Color.primary.opacity(0.12))
            .frame(
                width: axis == .vertical ? 5 : nil,
                height: axis == .horizontal ? 5 : nil
            )
            .frame(maxWidth: axis == .horizontal ? .infinity : nil, maxHeight: axis == .vertical ? .infinity : nil)
            .contentShape(Rectangle().inset(by: -4))
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
