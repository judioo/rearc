import AppKit
import SwiftUI
import SidebarModel

/// Root window layout: sidebar on the left, web content filling the rest,
/// command bar floating centered on top. The window background is the
/// focused space's theme (Arc `WindowTheme`), with the page inset on it as a
/// rounded card; it follows a space swipe and crossfades on other switches. With the sidebar hidden (Cmd+S), pointing
/// at the window's leading edge floats it over the page until the pointer
/// leaves (Arc `SidebarHovering`).
struct BrowserView: View {
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
            // ⌘S pushes the sidebar with the card's leading edge; the card
            // is laid out beside it only at rest (`isSidebarLaidOut`).
            ZStack(alignment: .topLeading) {
                contentCard
                if model.isSidebarVisible || model.isSidebarSliding, !isPageFullscreen {
                    SidebarView(model: model, draggedItemID: $draggedItemID)
                        .offset(x: (model.sidebarReveal - 1) * model.sidebarWidth)
                }
            }
            // The sidebar and card run up under the title bar: the traffic
            // lights sit on the theme like the rest of the sidebar (§4.5).
            .ignoresSafeArea(.container, edges: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) { if !isPageFullscreen { zoomBadge } }
            .background(SpaceThemeBackground(model: model, window: windowID, pager: pager).ignoresSafeArea())

            if !model.isSidebarVisible, model.isSidebarPeeking, !isPageFullscreen {
                HStack(spacing: 0) {
                    SidebarView(model: model, draggedItemID: $draggedItemID)
                        .background(SpaceThemeBackground(model: model, window: windowID, pager: pager))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.25), radius: 12, x: 2)
                        .padding(.vertical, 6)
                        .padding(.leading, 6)
                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
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
        .animation(.easeInOut(duration: 0.15), value: model.isCommandBarPresented)
        .frame(minWidth: 760, minHeight: 520)
        .background(
            DragSessionEndMonitor(isActive: draggedItemID != nil) { draggedItemID = nil }
                .frame(width: 0, height: 0)
        )
        .background(
            WindowOcclusionReader { model.handleWindowOcclusion($0) }
                .frame(width: 0, height: 0)
        )
        // Arc hides the traffic lights with the sidebar (ARC-RECORDING-ANALYSIS.md §3).
        .background(TrafficLightPositioner(isHidden: !model.isSidebarVisible && !model.isSidebarPeeking && !isPageFullscreen)
            .frame(width: 0, height: 0))
        // The shown space's Appearance (Automatic, Light, Dark) sets the
        // window's, which its pages, easels and notes follow.
        .background(
            WindowAppearanceSetter(appearance: model.space(in: windowID).theme.appearance)
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
                }
            )
            .frame(width: 0, height: 0)
        )
        .background(
            SidebarEdgeHoverMonitor(
                isEnabled: !model.isSidebarVisible && !isPageFullscreen,
                isPeeking: model.isSidebarPeeking,
                dismissWidth: model.sidebarWidth + 36,
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
        .sheet(isPresented: Binding(
            get: { model.spaceCreationDraft != nil && isKeyWindowSheetOwner },
            set: { if !$0 { model.spaceCreationDraft = nil } }
        )) {
            if let draft = model.spaceCreationDraft {
                SpaceCreationView(model: model, draft: draft)
            }
        }
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

    /// The focused space's chrome colours in its resolved appearance.
    private var themeChrome: ThemeChromeColors {
        let theme = model.space(in: windowID).theme
        let dark = theme.appearance.isDark(systemDark: SystemAppearance.isDark(colorScheme))
        return model.themeColors.colors(for: model.space(in: windowID).id, theme: theme, dark: dark)
    }

    /// This window shows a page in HTML fullscreen: only the page, edge to edge.
    private var isPageFullscreen: Bool {
        model.isHTMLFullscreen(in: windowID)
    }

    private var spaceProfileChangeText: (title: String, message: String, action: String) {
        model.pendingSpaceProfileChange.map(model.spaceProfileChangeMessage) ?? ("", "", "")
    }

    /// Only the key window presents the shared New Space sheet.
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
    @ViewBuilder
    private var zoomBadge: some View {
        if let engine = model.focusedEngine(in: windowID), !PageZoom.isDefault(engine.zoomFactor) {
            Button("\(PageZoom.percent(engine.zoomFactor))%") { model.zoom(.reset) }
                .buttonStyle(.plain)
                .font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(10)
                .help("Page zoom — click to reset to 100% (⌘0)")
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
    /// is 70 % white over the theme, so an empty card is tinted by it. With
    /// "URL in toolbar" on, the toolbar strip sits at its top (§4.4). With
    /// the sidebar hidden it is inset on every side. In HTML fullscreen the
    /// same view loses its inset and corners: a different view tree would
    /// detach the page, which ends fullscreen.
    private var contentCard: some View {
        let fullscreen = isPageFullscreen
        let radius: CGFloat = fullscreen ? 0 : Self.cardRadius
        let inset: CGFloat = fullscreen ? 0 : Self.cardInset
        let showsToolbar = urlInToolbar && !fullscreen
            && model.librarySection(in: windowID) == nil && model.selectedEaselRef(in: windowID) == nil
        let slide = fullscreen ? SidebarSlide() : SidebarSlide(
            reveal: model.sidebarReveal, width: model.sidebarWidth, inset: inset,
            showing: model.isSidebarVisible, laidOut: model.isSidebarLaidOut
        )
        let shape = CardShape(radius: radius, leadingCut: slide.cut)
        return VStack(spacing: 0) {
            if showsToolbar {
                CardToolbarView(model: model)
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
        .shellToast(model.isKeyBrowserWindow(windowID) ? model.toast : nil)
        .clipShape(shape)
        .background(shape.fill(cardFill))
        .background(CardShadow(shape: shape).opacity(fullscreen ? 0 : 1))
        .padding(.vertical, inset)
        .padding(.trailing, inset)
        .padding(.leading, model.isSidebarLaidOut && !fullscreen ? model.sidebarWidth : inset)
        .offset(x: slide.offset)
        .ignoresSafeArea(edges: fullscreen ? .all : [])
    }

    static let cardInset: CGFloat = 10
    static let cardRadius: CGFloat = 8

    /// About 70 % white over the theme in light (`#F6F4FA` → `#FAF7F7` on the
    /// default). In dark the card has no wash: an empty page shows the
    /// gradient at full strength (ARC-RECORDING-ANALYSIS.md §2.7, frame 1000).
    private var cardFill: Color {
        themeChrome.isWindowDark ? Color.clear : Color.white.opacity(0.7)
    }

    @ViewBuilder
    private var contentArea: some View {
        if model.startupDeferred {
            Color.clear.accessibilityLabel("Loading page")
        } else if let section = model.librarySection(in: windowID) {
            LibraryView(model: model, window: windowID, section: section)
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
            SplitContentView(split: split, model: model, accent: model.themeColor(in: windowID))
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

/// The card's rounded rectangle less a strip at its leading edge (the part
/// a sliding sidebar still covers). The strip animates with the sidebar.
struct CardShape: Shape {
    var radius: CGFloat
    var leadingCut: CGFloat = 0

    var animatableData: CGFloat {
        get { leadingCut }
        set { leadingCut = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let card = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        let cut = min(max(leadingCut, 0), rect.width)
        guard cut > 0 else { return card }
        return card.intersection(Path(CGRect(x: rect.minX + cut, y: rect.minY, width: rect.width - cut, height: rect.height)))
    }
}

/// Watches pointer movement in its window: reports `true` when the pointer
/// reaches the leading edge while the sidebar is hidden, `false` once it moves
/// clear of the floating sidebar. A local event monitor sees moves over web
/// content too (WKWebView or the Chromium host view), which SwiftUI hover
/// tracking on an overlay would not reliably get.
struct SidebarEdgeHoverMonitor: NSViewRepresentable {
    var isEnabled: Bool
    var isPeeking: Bool
    /// Past this x the floating sidebar hides again (its width plus a margin).
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
            let x = event.locationInWindow.x
            let y = event.locationInWindow.y
            let inside = y >= 0 && y <= window.frame.height
            if !parent.isPeeking, inside, x >= 0, x <= SidebarEdgeHoverMonitor.revealWidth {
                parent.onChange(true)
            } else if parent.isPeeking, x > parent.dismissWidth || !inside {
                parent.onChange(false)
            }
        }
    }
}
