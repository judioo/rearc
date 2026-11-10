import AppKit
import SwiftUI
import SidebarModel

/// One split pane's toolbar row (SPLIT-VIEW §3.1, Arc's split capture
/// 2026-11-08): back and forward, the pane's own address (link glyph, host
/// darker than the rest) and a ✕ that closes the pane. The focused pane's row
/// adds reload, the extensions, the site controls and the split menu. It reads
/// only its own engine, so one pane loading leaves the other rows alone.
struct SplitPaneToolbarView: View, Equatable {
    let model: BrowserViewModel
    let splitID: SplitViewItem.ID
    let orientation: SplitLayoutOrientation
    let tab: Tab
    let engine: any WebEngine
    let row: SplitPaneToolbarLayout.Row
    /// The first row clears the traffic lights with the sidebar on the right.
    var trafficLightsClearance: CGFloat = 0
    @Environment(\.sidebarWindow) private var window
    @Environment(\.themeChrome) private var chrome
    @State private var showsSiteControls = false
    @State private var siteControlsAnchor: NSView?
    @State private var isHoveringURL = false
    @AppStorage(ToolbarURLPreference.key) private var urlInToolbar = ToolbarURLPreference.defaultValue
    @AppStorage(ToolbarPageColorPreference.key) private var matchesPageColor = ToolbarPageColorPreference.defaultValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The split re-renders on every divider drag step; a row's body runs
    /// again only when its own inputs change.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.splitID == rhs.splitID && lhs.orientation == rhs.orientation && lhs.tab == rhs.tab
            && lhs.engine === rhs.engine && lhs.row == rhs.row && lhs.trafficLightsClearance == rhs.trafficLightsClearance
    }

    var body: some View {
        // Each pane's row takes its own page's colour.
        let tint = matchesPageColor ? engine.pageColor : nil
        let ink = CardToolbarInk(chrome: chrome, tint: tint)
        let url = engine.currentURL ?? tab.url
        let side = model.sidebarSide
        let showsToggle = !model.isSidebarVisible
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsToggle, side == .left, row.isAtLeadingCorner {
                    CardToolbarButton(symbol: side.toggleSymbol, help: "Show Sidebar (⌘S)") { model.toggleSidebar() }
                }
                CardToolbarButton(symbol: "arrow.left", help: "Back (⌘[)", enabled: engine.canGoBack) { engine.goBack() }
                CardToolbarButton(symbol: "arrow.right", help: "Forward (⌘])", enabled: engine.canGoForward) { engine.goForward() }
                if row.isActive {
                    if engine.isLoading {
                        CardToolbarButton(symbol: "xmark", help: "Stop Loading (⌘.)") { engine.stopLoading() }
                    } else {
                        CardToolbarButton(symbol: "arrow.clockwise", help: "Reload (⌘R, ⇧⌘R ignores the cache)") {
                            engine.reload(ignoringCache: NSEvent.modifierFlags.contains(.shift))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The address takes its width first; the two sides share the rest,
            // so a short address is centred and a long one fills the row.
            address(url, ink: ink)
                .layoutPriority(1)

            HStack(spacing: 0) {
                if row.isActive { paneControls(url, ink: ink) }
                Button { model.closeSplitPaneFromToolbar(tab.id, separating: NSEvent.modifierFlags.contains(.option)) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13))
                        .frame(width: 32, height: CardToolbarView.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .addressBarControlFocus()
                .foregroundStyle(ink.ink)
                .help("Close Pane (⌥-click to separate it from the split)")
                .accessibilityLabel("Close Pane")
                if showsToggle, side == .right, row.isAtTrailingCorner {
                    CardToolbarButton(symbol: side.toggleSymbol, help: "Show Sidebar (⌘S)") { model.toggleSidebar() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 2.5)
        .padding(.leading, row.isAtLeadingCorner ? trafficLightsClearance : 0)
        .frame(height: CardToolbarView.height)
        .pageColorToolbar(tint, palette: ink, reduceMotion: reduceMotion)
        .transformPreference(AddressBarFocusPreference.self) { $0 = $0 || showsSiteControls }
        .onChange(of: model.siteControlCenterRequest) { _, _ in
            if row.isActive, SiteControlCenter.site(for: url) != nil, model.isKeyBrowserWindow(window) { showsSiteControls = true }
        }
        .contextMenu {
            Button("Copy URL") { model.copyURL(of: tab.id) }
            Divider()
            Button("Show URL in Sidebar") { urlInToolbar = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.isActive ? "Focused pane toolbar" : "Pane toolbar")
    }

    private func address(_ url: URL?, ink: CardToolbarInk) -> some View {
        let parts = SplitPaneToolbarLayout.addressParts(url)
        return Button { model.editAddress(ofPane: tab.id, in: splitID) } label: {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ink.ink)
                Group {
                    if let parts {
                        Text(parts.host).foregroundColor(ink.ink) + Text(parts.rest).foregroundColor(ink.quiet)
                    } else {
                        Text("Search or Enter URL…").foregroundColor(ink.quiet)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(ink.hover.opacity(isHoveringURL ? 1 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .addressBarControlFocus()
        .onHover { isHoveringURL = $0 }
        .help(url?.absoluteString ?? "Open the command bar (⌘L)")
        .accessibilityLabel("Address of pane: \(parts.map { $0.host + $0.rest } ?? "blank")")
    }

    @ViewBuilder
    private func paneControls(_ url: URL?, ink: CardToolbarInk) -> some View {
        let site = SiteControlCenter.site(for: url)
        ExtensionToolbarView(model: model, engine: engine)
            .foregroundStyle(ink.extensionInk)
        Button { showsSiteControls.toggle() } label: {
            Image(systemName: "slider.horizontal.2.square")
                .font(.system(size: 15))
                .frame(width: 36, height: CardToolbarView.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .addressBarControlFocus()
        .foregroundStyle(ink.ink)
        .disabled(site == nil)
        .background(AnchorReader { siteControlsAnchor = $0 })
        .help(site.map { "Site controls for \($0.host)" } ?? "Site controls")
        .accessibilityLabel("Site controls")
        .popover(isPresented: $showsSiteControls, arrowEdge: .bottom) {
            if let site {
                SiteControlCenterView(model: model, engine: engine, site: site, anchor: siteControlsAnchor) {
                    showsSiteControls = false
                }
            }
        }
        splitMenu(ink: ink)
    }

    /// Arc's split view control (`contentToolbarSplitViewMenu`): the split's
    /// own menu items, for this pane.
    private func splitMenu(ink: CardToolbarInk) -> some View {
        Menu {
            Button("Add Tab to Split View") { model.addBlankPane(to: splitID) }
            Button(orientation == .horizontal ? "Arrange Top and Bottom" : "Arrange Side by Side") {
                model.flipSplitOrientation(splitID)
            }
            Button(!model.isSplitExpanded(splitID, in: window) ? "Expand Current Split" : "Show Split View") {
                model.toggleExpandedSplitPane(splitID, in: window)
            }
            Divider()
            Button("Separate from Split View") { model.unsplitTabIfInSplit(tab.id) }
            Button("Separate All Tabs") { model.unsplit(splitID) }
            Divider()
            Button("Close Split View") { model.closeSplit(splitID) }
        } label: {
            Image(systemName: orientation == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2")
                .font(.system(size: 13))
                .frame(width: 36, height: CardToolbarView.height)
                .contentShape(Rectangle())
        }
        // A plain button keeps the glyph in the toolbar's ink (the borderless style dims it).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .addressBarControlFocus()
        .menuIndicator(.hidden)
        .foregroundStyle(ink.ink)
        .fixedSize()
        .help("Split View")
        .accessibilityLabel("Split View menu")
    }
}
