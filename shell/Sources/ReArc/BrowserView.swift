import AppKit
import SwiftUI
import SidebarModel

/// Root window layout: sidebar on the left (or the right, P3.14), web content filling the rest,
/// command bar floating centered on top. The window background is the
/// focused space's theme (Arc `WindowTheme`), with the page inset on it as a
/// rounded card; it follows a space swipe and crossfades on other switches. With the sidebar hidden (Cmd+S), pointing
/// at the window's leading edge floats it over the page until the pointer
/// leaves (Arc `SidebarHovering`).
struct BrowserView: View {
    /// The browser window's smallest content size (the Chromium shell sets it on the window).
    static let minimumSize = CGSize(width: 760, height: 520)

    @Bindable var model: BrowserViewModel
    @Environment(\.openWindow) private var openWindow
    /// This window's identity for its own focused space (Arc `focusedSpaceID`).
    @State private var windowID: SidebarWindowID
    /// The space a restored window opens on (nil: the key window's).
    private let initialSpaceID: Space.ID?
    /// This window's space paging (swipe and animated switches).
    @State private var pager = SpacePagerController()
    /// The sidebar item being dragged, if any (content edges then offer split drop zones).
    @State private var draggedItemID: UUID?
    @AppStorage(ToolbarURLPreference.key) private var urlInToolbar = ToolbarURLPreference.defaultValue
    @Environment(\.colorScheme) private var colorScheme

    init(model: BrowserViewModel, windowID: SidebarWindowID = SidebarWindowID(), initialSpaceID: Space.ID? = nil) {
        self.model = model
        _windowID = State(initialValue: windowID)
        self.initialSpaceID = initialSpaceID
    }

    var body: some View {
        ZStack {
            // ⌘S pushes the sidebar with the card's edge beside it; the card
            // is laid out beside it only at rest (`isSidebarLaidOut`).
            ZStack(alignment: Alignment(horizontal: placement.side.horizontalAlignment, vertical: .top)) {
                contentCard
                if model.isSidebarVisible || model.isSidebarSliding, !isPageFullscreen {
                    let width = model.sidebarWidth(in: windowID)
                    SidebarView(model: model, draggedItemID: $draggedItemID)
                        .offset(x: CGFloat(placement.sidebarOffset(reveal: model.sidebarReveal, width: Double(width),
                                                                   growth: model.sidebarGrowth(in: windowID))))
                }
            }
            // An extension's side panel (ABI 1.47) at the window's other
            // edge; one on the sidebar's side is laid out with the card.
            .extensionSidePanel(model.extensions, window: windowID, side: sidePanelLayout.side,
                                topInset: sidePanelLayout.clearsTrafficLights ? TrafficLightPositioner.cardClearance : Self.cardInset,
                                isHidden: isPageFullscreen || sidePanelLayout.isBesideSidebar)
            // The sidebar and card run up under the title bar: the traffic
            // lights sit on the theme like the rest of the sidebar (§4.5).
            .ignoresSafeArea(.container, edges: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A side change swaps the layout once, while both are faded out.
            .opacity(model.sidebarFlipOpacity)
            .background(SpaceThemeBackground(model: model, window: windowID, pager: pager).ignoresSafeArea())

            if !model.isSidebarVisible, model.isSidebarPeeking, !isPageFullscreen {
                let edge = placement.side.edge
                HStack(spacing: 0) {
                    if edge == .trailing { Spacer(minLength: 0) }
                    SidebarView(model: model, draggedItemID: $draggedItemID)
                        .background(SpaceThemeBackground(model: model, window: windowID, pager: pager))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.25), radius: 12, x: 2 * CGFloat(placement.inward))
                        .padding(.vertical, 6)
                        .padding(edge == .leading ? .leading : .trailing, 6)
                    if edge == .leading { Spacer(minLength: 0) }
                }
                .transition(.move(edge: edge).combined(with: .opacity))
            }

            if let session = model.peekSession, let web = model.peekEngineView() {
                PeekOverlayView(
                    title: session.title,
                    url: session.url,
                    webContent: web,
                    onOpenInTab: { model.peekOpenInFullTab() },
                    onOpenInLittleArc: { model.peekOpenInLittleArc() },
                    onCopyLink: { model.peekCopyLink() },
                    onDismiss: { model.dismissPeek() }
                )
            }

            boostEditorChrome

            if model.sidebarRecoveredFromCorruption {
                VStack {
                    Text("Recovered from a corrupted file — your previous state was preserved separately")
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            }

            if model.isCommandBarPresented {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .onTapGesture { model.dismissCommandBar() }
                // Centred on the window, not the card, its top 38 % down (ARC-RECORDING-ANALYSIS.md §8).
                GeometryReader { geometry in
                    commandBar(width: min(CommandBarOverlay.arcWidth, geometry.size.width - 40))
                        .frame(maxWidth: .infinity)
                        .padding(.top, max(20, min(geometry.size.height * CommandBarOverlay.topFraction, geometry.size.height - 440)))
                }
                .ignoresSafeArea()
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if let switcher = model.tabSwitcher, isKeyWindowSheetOwner {
                TabSwitcherOverlay(
                    session: switcher,
                    favicon: { item in model.store.tab(withID: item.id).flatMap { model.favicon(for: $0) } },
                    onSelect: { model.selectTabSwitcherItem($0) }
                )
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) { BrowserProbeMarkers(model: model, pager: pager) }
        .tint(model.themeColor(in: windowID))
        .environment(\.themeChrome, themeChrome)
        .environment(\.sidebarWindow, windowID)
        .environment(\.spacePager, pager)
        // Arc's bar is complete in its first frame: it opens without a
        // transition and only fades out (docs/PERF-BASELINE.md, "Arc vs ReArc").
        .animation(model.isCommandBarPresented ? nil : .easeInOut(duration: 0.15), value: model.isCommandBarPresented)
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .background(
            DragSessionEndMonitor(isActive: draggedItemID != nil) { draggedItemID = nil }
                .frame(width: 0, height: 0)
        )
        .background(
            WindowOcclusionReader { model.handleWindowOcclusion($0) }
                .frame(width: 0, height: 0)
        )
        // Arc hides the traffic lights with the sidebar (ARC-RECORDING-ANALYSIS.md §3).
        // With the sidebar on the right they stay at the top left, in the card's toolbar strip.
        .background(TrafficLightPositioner(isHidden: !showsTrafficLights,
                                           centreY: trafficLightsCentreY)
            .frame(width: 0, height: 0))
        // The shown space's Appearance (Automatic, Light, Dark) sets the
        // window's, which its pages, easels and notes follow.
        .background(
            WindowAppearanceSetter(appearance: model.shownTheme(in: windowID).appearance)
                .frame(width: 0, height: 0)
        )
        .background(
            WindowKeyObserver(
                onBecameKey: { model.windowBecameKey(windowID) },
                onClose: {
                    model.store.unregisterWindow(windowID)
                    model.pinnedSectionCollapse.forgetWindow(windowID)
                    model.splitMaximize.forgetWindow(windowID)
                    model.library.forgetWindow(windowID)
                    model.libraryGrowth[windowID] = nil
                }
            )
            .frame(width: 0, height: 0)
        )
        .background(
            SidebarEdgeHoverMonitor(
                placement: placement,
                isEnabled: !model.isSidebarVisible && !isPageFullscreen,
                isPeeking: model.isSidebarPeeking,
                dismissWidth: model.sidebarWidth(in: windowID) + 36,
                onChange: { model.setSidebarPeeking($0) }
            )
            .frame(width: 0, height: 0)
        )
        .navigationTitle(contentTitle)
        .sheet(isPresented: $model.isCapturePreviewPresented) {
            if let record = model.lastCapturePreview {
                CapturePreviewSheet(record: record, model: model)
            }
        }
        .alert("Capture failed", isPresented: Binding(
            get: { model.captureErrorMessage != nil },
            set: { if !$0 { model.captureErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.captureErrorMessage ?? "")
        }
        .alert("Default Browser", isPresented: Binding(
            get: { model.defaultBrowserMessage != nil && isKeyWindowSheetOwner },
            set: { if !$0 { model.defaultBrowserMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.defaultBrowserMessage = nil }
        } message: {
            Text(model.defaultBrowserMessage ?? "")
        }
        .onAppear {
            ExternalLinkRouter.shared.attach(model)
            model.installTabSwitcherMonitor()
            model.startLittleArcHotkey()
            model.store.registerWindow(windowID, spaceID: initialSpaceID)
            stripCloseWindowShortcut()
            model.restoreLittleArcWindowsIfNeeded()
        }
        // Any other item shown in this window (a shortcut, a space switch)
        // closes its Library for good.
        .onChange(of: model.selectedItemID(in: windowID)) { _, _ in
            model.library.closeStale { model.selectedItemID(in: $0) }
        }
        .onChange(of: model.littleArcOpenRequests) { _, requests in
            for id in requests {
                openWindow(id: "littleArc", value: id)
            }
            if !requests.isEmpty {
                model.clearLittleArcOpenRequests()
            }
        }
        .onChange(of: model.isAirTrafficControlPresented) { _, presented in
            guard presented else { return }
            model.isAirTrafficControlPresented = false
            openWindow(id: "airTrafficControl")
        }
        .onChange(of: model.privateWindowOpenRequests) { _, requests in
            for id in requests {
                openWindow(id: "private", value: id)
            }
            if !requests.isEmpty {
                model.clearPrivateWindowOpenRequests()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.prepareForQuit()
        }
        .sheet(isPresented: Binding(
            get: { model.legacyBoostEditorID != nil && isKeyWindowSheetOwner },
            set: { if !$0 { model.legacyBoostEditorID = nil } }
        )) {
            if let id = model.legacyBoostEditorID {
                LegacyBoostEditorView(model: model, packageID: id)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.spaceEditorID != nil },
            set: { if !$0 { model.spaceEditorID = nil } }
        )) {
            if let id = model.spaceEditorID {
                SpaceEditorView(model: model, spaceID: id)
            }
        }
        .modifier(SidebarPersonalizationSheets(model: model, isOwner: isKeyWindowSheetOwner))
        .alert(model.pendingRename?.alertTitle ?? "Rename", isPresented: Binding(
            get: { model.pendingRename != nil },
            set: { if !$0 { model.pendingRename = nil } }
        )) {
            TextField("Name", text: $model.pendingRenameText)
            Button("Cancel", role: .cancel) { model.pendingRename = nil }
            Button("Save") { model.commitRename() }
        } message: {
            if case .tab = model.pendingRename {
                Text("Leave empty to use the page title.")
            }
        }
        .alert(model.pendingDeletionMessage.title, isPresented: Binding(
            get: { model.pendingDeletion != nil },
            set: { if !$0 { model.pendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { model.pendingDeletion = nil }
            Button(model.pendingDeletionMessage.action, role: .destructive) { model.confirmPendingDeletion() }
        } message: {
            Text(model.pendingDeletionMessage.message)
        }
        .alert(spaceProfileChangeText.title, isPresented: Binding(
            get: { model.pendingSpaceProfileChange != nil && isKeyWindowSheetOwner },
            set: { if !$0 { model.pendingSpaceProfileChange = nil } }
        )) {
            Button("Cancel", role: .cancel) { model.pendingSpaceProfileChange = nil }
            Button(spaceProfileChangeText.action) { model.confirmSpaceProfileChange() }
        } message: {
            Text(spaceProfileChangeText.message)
        }
        .alert("Rename Profile", isPresented: Binding(
            get: { model.pendingProfileRenameID != nil },
            set: { if !$0 { model.pendingProfileRenameID = nil } }
        )) {
            TextField("Name", text: $model.pendingProfileRenameName)
            Button("Cancel", role: .cancel) { model.pendingProfileRenameID = nil }
            Button("Save") {
                if let id = model.pendingProfileRenameID {
                    _ = model.store.renameProfile(id, to: model.pendingProfileRenameName)
                }
                model.pendingProfileRenameID = nil
            }
        }
    }

    private func commandBar(width: CGFloat) -> some View {
        CommandBarContainer(model: model, width: width)
    }

    /// The focused space's chrome colours in its resolved appearance, or
    /// Create a Space's draft while the window shows it.
    private var themeChrome: ThemeChromeColors {
        let theme = model.shownTheme(in: windowID)
        let dark = theme.appearance.isDark(systemDark: SystemAppearance.isDark(colorScheme))
        let id = model.isCreatingSpace(in: windowID) ? SpaceCreationSession.pageID : model.space(in: windowID).id
        return model.themeColors.colors(for: id, theme: theme, dark: dark)
    }

    private var placement: SidebarPlacement { model.sidebarPlacement }
    private var sidePanelLayout: SidePanelLayout { model.sidePanelLayout }

    /// The card's toolbar strip, when shown (it holds the traffic lights with the sidebar on the right).
    private var showsCardToolbar: Bool {
        urlInToolbar && !isPageFullscreen
            && model.librarySection(in: windowID)?.coversPage != true && model.selectedEaselRef(in: windowID) == nil
    }

    /// Arc's height in the sidebar's top row; on the right, the card toolbar's middle.
    private var trafficLightsCentreY: CGFloat {
        guard !placement.trafficLightsInSidebar, showsCardToolbar else { return TrafficLightPositioner.centreY }
        return Self.cardInset + CardToolbarView.height / 2
    }

    /// This window shows a page in HTML fullscreen: only the page, edge to edge.
    private var isPageFullscreen: Bool {
        model.isHTMLFullscreen(in: windowID)
    }

    private var spaceProfileChangeText: (title: String, message: String, action: String) {
        model.pendingSpaceProfileChange.map(model.spaceProfileChangeMessage) ?? ("", "", "")
    }

    /// Only the key window presents the shared sheets.
    private var isKeyWindowSheetOwner: Bool {
        model.store.keyWindowID == nil || model.store.keyWindowID == windowID
    }

    private var contentTitle: String {
        if let section = model.librarySection(in: windowID) {
            return section.title
        }
        if let ref = model.selectedEaselRef(in: windowID) {
            return model.easelTitle(for: ref)
        }
        return model.selectedTab(in: windowID)?.displayTitle ?? "ReArc"
    }

    /// Removes ⌘W from File > Close Window so the Tabs menu's Close Tab
    /// command is the only ⌘W in the app. The window can still be closed
    /// with the red traffic-light button.
    private func stripCloseWindowShortcut() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for topItem in mainMenu.items {
            guard let submenu = topItem.submenu else { continue }
            for item in submenu.items
            where item.keyEquivalent == "w"
                && item.keyEquivalentModifierMask == .command
                && item.action == NSSelectorFromString("performClose:") {
                item.keyEquivalent = ""
            }
        }
    }

    /// Shown while the focused tab is not at 100%; clicking resets it (Cmd+0).
    /// At the card's top right, so a sidebar or side panel beside it on the right moves it in.
    /// A split draws it in the focused pane instead (`SplitContentView`).
    @ViewBuilder
    private var zoomBadge: some View {
        if shownSplit == nil, let engine = model.focusedEngine(in: windowID) {
            PageZoomBadge(engine: engine, topInset: showsCardToolbar ? CardToolbarView.height : 0)
        }
    }

    @ViewBuilder
    private var boostEditorChrome: some View {
        if let draft = model.boostEditorDraft {
            VStack {
                if draft.pickerActive {
                    Text("Pick an element — Esc to cancel")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(draft.pickerActive)

            BoostEditorDrawerView(model: model, draft: draft)
        }
    }

    /// The page as a rounded card inset on the theme background (Arc's
    /// content frame, THEMES.md §4.3): 10 pt from the top, right and bottom,
    /// flush with the sidebar, 8 pt corners and a soft shadow. Its own fill
    /// is 62 % white over the theme, so an empty card is tinted by it and
    /// changes colour with a swipe. With
    /// "URL in toolbar" on, the toolbar strip sits at its top (§4.4). With
    /// the sidebar hidden it is inset on every side. With the sidebar on the
    /// right it is the mirror, and without the strip its top clears the
    /// traffic lights. An extension side panel on the sidebar's side sits
    /// between the two: the sidebar's lead is outside both, so ⌘S and the
    /// Library's widening move the pane with the card (`SidePanelLayout`). In
    /// HTML fullscreen the same view loses its inset and
    /// corners: a different view tree would detach the page, which ends fullscreen.
    private var contentCard: some View {
        let fullscreen = isPageFullscreen
        let radius: CGFloat = fullscreen ? 0 : Self.cardRadius
        let inset: CGFloat = fullscreen ? 0 : Self.cardInset
        let showsToolbar = showsCardToolbar
        let placement = placement
        let topInset = fullscreen || showsToolbar || placement.trafficLightsInSidebar ? inset : TrafficLightPositioner.cardClearance
        let sidebarWidth = model.sidebarWidth(in: windowID)
        // The Library widening the sidebar moves the page without laying it out again.
        let growth = fullscreen ? nil : model.sidebarGrowth(in: windowID)
        let slide = fullscreen ? SidebarSlide() : SidebarSlide(
            reveal: model.sidebarReveal, width: sidebarWidth, inset: inset,
            showing: model.isSidebarVisible, laidOut: model.isSidebarLaidOut
        )
        let shape = CardShape(radius: radius, sidebarCut: slide.cut, cutEdge: placement.cardSidebarEdge)
        let panelLayout = sidePanelLayout
        let lead = fullscreen ? 0 : SidePanelLayout.lead(sidebarLaidOut: model.isSidebarLaidOut,
                                                          sidebarWidth: growth.map(\.from) ?? Double(sidebarWidth),
                                                          inset: Double(inset))
        // A split's panes are cards of their own, each with its own row (SPLIT-VIEW §3.1).
        let splitCards = !fullscreen && shownSplit != nil
        return VStack(spacing: 0) {
            if showsToolbar, shownSplit == nil {
                CardToolbarView(model: model, trafficLightsClearance: cardToolbarTrafficLightsClearance)
                    .zIndex(1)
            }
            contentArea
                .overlay {
                    if let session = model.pageCaptureSession,
                       session.window == nil ? isKeyWindowSheetOwner : session.window == windowID {
                        PageCaptureOverlay(model: model)
                    }
                }
                .overlay {
                    if let dragged = draggedItemID, model.canDropToSplit(dragged, in: windowID) {
                        ContentSplitDropZone(draggedItemID: dragged, accent: model.themeColor(in: windowID)) { id, edge in
                            draggedItemID = nil
                            return model.dropToSplit(id, edge: edge, in: windowID)
                        }
                    }
                }
        }
        .shellToast(model.isKeyBrowserWindow(windowID) ? model.toast : nil) { start in
            if start { model.startPendingExtensionReinstall() } else { model.postponePendingExtensionReinstall() }
        }
        .clipShape(shape)
        .background(shape.fill(splitCards ? .clear : cardFill))
        .background(CardShadow(shape: shape).opacity(fullscreen ? 0 : 1))
        .overlay { LibrarySpacesOverlay(model: model, window: windowID) }
        .overlay(alignment: .topTrailing) { if !fullscreen { zoomBadge } }
        .padding(.top, topInset)
        .padding(.bottom, inset)
        .padding(.horizontal, inset)
        .extensionSidePanel(model.extensions, window: windowID, side: panelLayout.side, topInset: topInset,
                            paneOffset: CGFloat(panelLayout.paneOffset(sidebarCut: Double(slide.cut))),
                            isHidden: fullscreen || !panelLayout.isBesideSidebar)
        .padding(placement.side.edgeSet, CGFloat(lead))
        .offset(x: CGFloat(placement.pageOffset(slide: Double(slide.offset), growth: growth)))
        .ignoresSafeArea(edges: fullscreen ? .all : [])
    }

    /// With the sidebar on the right the toolbar's first glyph starts after the traffic lights.
    private var cardToolbarTrafficLightsClearance: CGFloat {
        placement.trafficLightsInSidebar || !showsTrafficLights ? 0 : TrafficLightPositioner.titlebarWidth - Self.cardInset
    }

    /// The split the content area shows, if it shows one (`contentArea`'s order).
    private var shownSplit: SplitViewItem? {
        guard !model.startupDeferred, model.librarySection(in: windowID)?.coversPage != true,
              model.selectedEaselRef(in: windowID) == nil else { return nil }
        return model.activeSplit(in: windowID)
    }

    /// The traffic lights show with the sidebar, as in Arc (ARC-RECORDING-ANALYSIS.md §3).
    private var showsTrafficLights: Bool {
        (model.isSidebarVisible || model.isSidebarPeeking) && !isPageFullscreen
    }

    static let cardInset: CGFloat = 10
    static let cardRadius: CGFloat = 8

    /// About 62 % white over the theme in light: saturated themes put it
    /// at 0.60–0.65 (2026-11-06-space-swipe-feel-and-new-space.md §2.2; the
    /// pale default gave ≈ 70 %). In dark the card has no wash: an empty page
    /// shows the gradient at full strength (ARC-RECORDING-ANALYSIS.md §2.7).
    private var cardFill: Color {
        themeChrome.isWindowDark ? Color.clear : Color.white.opacity(0.62)
    }

    @ViewBuilder
    private var contentArea: some View {
        if model.startupDeferred {
            Color.clear.accessibilityLabel("Loading page")
        } else if let ref = model.selectedEaselRef(in: windowID),
           let document = model.easelDocument(forSidebarItem: ref.id) {
            if document.kind == .note {
                NoteEditorView(model: model, sidebarItemID: ref.id, document: document)
                    .id(document.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EaselEditorView(model: model, sidebarItemID: ref.id, document: document)
                    .id(document.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let split = model.activeSplit(in: windowID) {
            SplitContentView(
                split: split, model: model, accent: model.themeColor(in: windowID),
                showsRows: SplitPaneToolbarLayout.showsRows(urlInToolbar: showsCardToolbar, pageFullscreen: isPageFullscreen),
                showsCards: !isPageFullscreen, cardFill: cardFill,
                trafficLightsClearance: cardToolbarTrafficLightsClearance
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let tab = model.selectedTab(in: windowID) {
            let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
            if let frontend = model.dockedDevTools(for: tab.id) {
                DevToolsDockedLayout(model: model, tabID: tab.id, frontend: frontend) {
                    engine.makeView()
                        .id(tab.id)
                        .pageStatus(engine.activity) { engine.reload() }
                        .findBar(model.findBar, for: engine)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                engine.makeView()
                    .id(tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .pageStatus(engine.activity) { engine.reload() }
                    .findBar(model.findBar, for: engine)
            }
        } else {
            // Arc's empty card is blank: only the card fill shows.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("No tab selected. Press ⌘T to open one.")
        }
    }
}

/// The card's shadow without its shape: black 22 %, radius 3, 1.25 pt down,
/// fitted pixel by pixel to the capture (THEMES.md §4.3 estimated σ 3.5,
/// y 2.5). The shape itself is cut out, so the card's translucent fill is
/// not darkened by the shadow underneath it.
private struct CardShadow: View {
    let shape: CardShape

    var body: some View {
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

/// Where the card sits while ⌘S slides (ARC-RECORDING-ANALYSIS.md §3). The
/// sidebar's right edge is at `reveal × width`. Hiding, the card is already
/// laid out wide and the strip the sidebar still covers is cut away
/// (`cut`). Showing, the wide card moves right with the edge (`offset`)
/// until it is laid out narrow at the end.
struct SidebarSlide: Equatable {
    var cut: CGFloat = 0
    var offset: CGFloat = 0

    init() {}

    init(reveal: Double, width: CGFloat, inset: CGFloat, showing: Bool, laidOut: Bool) {
        let edge = CGFloat(reveal) * width
        if !showing { cut = max(0, edge - inset) }
        if showing, !laidOut { offset = CGFloat(reveal) * (width - inset) }
    }
}

/// The card's rounded rectangle less a strip at its edge beside the sidebar
/// (the part a sliding sidebar still covers). The strip animates with the sidebar.
struct CardShape: Shape {
    var radius: CGFloat
    var sidebarCut: CGFloat = 0
    var cutEdge: SidebarSide = .left

    var animatableData: CGFloat {
        get { sidebarCut }
        set { sidebarCut = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let card = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        let cut = min(max(sidebarCut, 0), rect.width)
        guard cut > 0 else { return card }
        let minX = cutEdge == .left ? rect.minX + cut : rect.minX
        return card.intersection(Path(CGRect(x: minX, y: rect.minY, width: rect.width - cut, height: rect.height)))
    }
}

/// Watches pointer movement in its window: reports `true` when the pointer
/// reaches the sidebar's edge while the sidebar is hidden, `false` once it moves
/// clear of the floating sidebar. A local event monitor sees moves over web
/// content too (WKWebView or the Chromium host view), which SwiftUI hover
/// tracking on an overlay would not reliably get.
struct SidebarEdgeHoverMonitor: NSViewRepresentable {
    var placement = SidebarPlacement(side: .left)
    var isEnabled: Bool
    var isPeeking: Bool
    /// This far from the edge the floating sidebar hides again (its width plus a margin).
    var dismissWidth: CGFloat
    var onChange: (Bool) -> Void

    static let revealWidth: CGFloat = 4

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak coordinator = context.coordinator] event in
            coordinator?.handle(event)
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        nsView.window?.acceptsMouseMovedEvents = true
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: SidebarEdgeHoverMonitor
        weak var view: NSView?
        var monitor: Any?

        init(parent: SidebarEdgeHoverMonitor) { self.parent = parent }

        func handle(_ event: NSEvent) {
            guard parent.isEnabled, let window = view?.window, event.window === window else { return }
            let x = Double(event.locationInWindow.x)
            let y = event.locationInWindow.y
            let width = Double(window.frame.width)
            let inside = y >= 0 && y <= window.frame.height
            let placement = parent.placement
            if !parent.isPeeking, inside,
               placement.revealsPeek(x: x, windowWidth: width, revealWidth: Double(SidebarEdgeHoverMonitor.revealWidth)) {
                parent.onChange(true)
            } else if parent.isPeeking,
                      placement.dismissesPeek(x: x, windowWidth: width, dismissWidth: Double(parent.dismissWidth)) || !inside {
                parent.onChange(false)
            }
        }
    }
}

/// The page's zoom while it is not at 100%; a click resets it (⌘0). Over the
/// page's top right, under its toolbar row (`topInset`) so it covers neither
/// the split nor the site controls button.
struct PageZoomBadge: View {
    let engine: any WebEngine
    var topInset: CGFloat = 0

    var body: some View {
        if !PageZoom.isDefault(engine.zoomFactor) {
            Button("\(PageZoom.percent(engine.zoomFactor))%") {
                engine.setZoomFactor(PageZoom.factor(after: .reset, from: engine.zoomFactor))
            }
            .buttonStyle(.plain)
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(10)
            .padding(.top, topInset)
            .help("Page zoom — click to reset to 100% (⌘0)")
        }
    }
}
