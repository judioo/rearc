import AppKit
import SwiftUI
import SidebarModel

/// Arc's toolbar strip inside the page card, shown with "URL in toolbar"
/// on (`topBarURLEnabled`, THEMES.md §4.4): 32 pt tall over the card's own
/// fill, back / forward / reload on a 37 pt pitch at the left, the address
/// centred, site controls and split view at the right, a hairline below.
struct CardToolbarView: View {
    let model: BrowserViewModel
    @Environment(\.sidebarWindow) private var window
    @Environment(\.themeChrome) private var chrome
    @State private var showsSiteControls = false
    @State private var siteControlsAnchor: NSView?
    @State private var isHoveringURL = false
    @AppStorage(ToolbarURLPreference.key) private var urlInToolbar = ToolbarURLPreference.defaultValue

    static let height: CGFloat = 32

    /// Measured greys (§4.4): enabled glyphs and the address, disabled glyphs, right icons.
    private var ink: Color { chrome.isDark ? Color(white: 0.78) : Color(.sRGB, red: 0.384, green: 0.384, blue: 0.392) }
    private var disabledInk: Color { chrome.isDark ? Color(white: 0.42) : Color(.sRGB, red: 0.714, green: 0.714, blue: 0.737) }
    private var quietInk: Color { chrome.isDark ? Color(white: 0.55) : Color(.sRGB, red: 0.733, green: 0.725, blue: 0.733) }

    var body: some View {
        let engine = model.focusedEngine(in: window)
        let tab = model.selectedTab(in: window)
        let url = engine?.currentURL ?? tab?.url
        let site = SiteControlCenter.site(for: url)
        ZStack {
            Button { model.focusLocation() } label: {
                Text(url.flatMap(Self.displayURL) ?? "Search or Enter URL…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Color.primary.opacity(isHoveringURL ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringURL = $0 }
            .help(url?.absoluteString ?? "Open the command bar (⌘L)")
            .padding(.horizontal, 140)
            .padding(.trailing, 20) // centred about 10 pt left of the card's centre
            .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                if !model.isSidebarVisible {
                    // With the sidebar hidden its toggle moves here, before back (§3).
                    navButton("sidebar.left", help: "Show Sidebar (⌘S)", enabled: true) { model.toggleSidebar() }
                }
                navButton("arrow.left", help: "Back (⌘[)", enabled: engine?.canGoBack == true) { model.goBack() }
                navButton("arrow.right", help: "Forward (⌘])", enabled: engine?.canGoForward == true) { model.goForward() }
                if engine?.isLoading == true {
                    navButton("xmark", help: "Stop Loading (⌘.)", enabled: true) { model.stopLoading() }
                } else {
                    navButton("arrow.clockwise", help: "Reload (⌘R, ⇧⌘R ignores the cache)", enabled: engine != nil) {
                        model.reload(ignoringCache: NSEvent.modifierFlags.contains(.shift))
                    }
                }
                Spacer(minLength: 0)
                ExtensionToolbarView(model: model, engine: engine)
                Button { showsSiteControls.toggle() } label: {
                    Image(systemName: "slider.horizontal.2.square")
                        .font(.system(size: 15))
                        .frame(width: 36, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(quietInk)
                .disabled(site == nil || engine == nil)
                .background(AnchorReader { siteControlsAnchor = $0 })
                .help(site.map { "Site controls for \($0.host)" } ?? "Site controls")
                .accessibilityLabel("Site controls")
                .popover(isPresented: $showsSiteControls, arrowEdge: .bottom) {
                    if let engine, let site {
                        SiteControlCenterView(model: model, engine: engine, site: site, anchor: siteControlsAnchor) {
                            showsSiteControls = false
                        }
                    }
                }
                Button { model.addSplitView(orientation: .horizontal) } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 13))
                        .frame(width: 36, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(quietInk)
                .help("Add Split View")
                .accessibilityLabel("Add Split View")
            }
            .padding(.horizontal, 2.5)
        }
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(chrome.isDark ? 0.12 : 0.05))
                .frame(height: 1)
                .offset(y: 1)
        }
        .onChange(of: model.siteControlCenterRequest) { _, _ in
            if site != nil, model.isKeyBrowserWindow(window) { showsSiteControls = true }
        }
        .contextMenu {
            Button("Copy URL") { model.copyURL() }.disabled(tab == nil)
            Divider()
            Button("Show URL in Sidebar") { urlInToolbar = false }
        }
    }

    private func navButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 37, height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? ink : disabledInk)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    /// The full address without its scheme or `www.` (Arc's
    /// `toolbarShowFullURLsEnabledPreference`); nil for a blank page.
    static func displayURL(_ url: URL) -> String? {
        if url.absoluteString == "about:blank" { return nil }
        guard let host = url.host(), !host.isEmpty else { return url.absoluteString }
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var rest = url.path(percentEncoded: false)
        if rest == "/" { rest = "" }
        if let query = url.query(percentEncoded: false), !query.isEmpty { rest += "?" + query }
        return bareHost + rest
    }
}

/// Puts the traffic lights where Arc draws them (THEMES.md §4.5): 14 pt
/// buttons on a 23 pt pitch, centred at x 19.5 / 42.5 / 65.5 and y 23.5 from
/// the window's top. AppKit lays the title bar out again on resize, key
/// changes and full screen, so it re-applies after each.
struct TrafficLightPositioner: NSViewRepresentable {
    static let firstCentreX: CGFloat = 19.5
    static let pitch: CGFloat = 23
    static let centreY: CGFloat = 23.5
    /// The title bar area tall enough to hold the buttons at that centre.
    static let titlebarHeight: CGFloat = 47
    static let titlebarWidth: CGFloat = 84

    static func titlebarFrame(windowSize: NSSize) -> NSRect {
        NSRect(x: 0, y: windowSize.height - titlebarHeight,
               width: min(titlebarWidth, windowSize.width), height: titlebarHeight)
    }

    /// The sidebar is hidden: so are the buttons, as in Arc.
    var isHidden = false

    func makeNSView(context: Context) -> PositionerView { PositionerView() }
    func updateNSView(_ nsView: PositionerView, context: Context) {
        nsView.buttonsHidden = isHidden
        nsView.reposition()
    }

    final class PositionerView: NSView {
        private var observers: [NSObjectProtocol] = []
        var buttonsHidden = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didChangeScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reposition() }
                }
            }
            reposition()
            DispatchQueue.main.async { [weak self] in self?.reposition() }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func reposition() {
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window?.standardWindowButton(kind), button.isHidden != buttonsHidden else { continue }
                button.isHidden = buttonsHidden
            }
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return }
            let height = TrafficLightPositioner.titlebarHeight
            // The titlebar container intercepts clicks even where it is transparent.
            // Keep it over the traffic lights, leaving the page toolbar and toast clickable.
            let frame = TrafficLightPositioner.titlebarFrame(windowSize: window.frame.size)
            if container.frame != frame { container.frame = frame }
            titlebar.frame = NSRect(x: 0, y: 0, width: container.bounds.width, height: height)
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, kind) in kinds.enumerated() {
                guard let button = window.standardWindowButton(kind) else { continue }
                let size = button.frame.size
                let centreX = TrafficLightPositioner.firstCentreX + TrafficLightPositioner.pitch * CGFloat(index)
                let fromTop = TrafficLightPositioner.centreY
                let y = titlebar.isFlipped ? fromTop - size.height / 2 : height - fromTop - size.height / 2
                let origin = NSPoint(x: (centreX - size.width / 2).rounded(), y: y.rounded())
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}
