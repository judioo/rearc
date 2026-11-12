import SwiftUI
import SidebarModel

/// The top of the sidebar: the traffic lights' row with Arc's
/// `sidebar.left` toggle 12 pt after the zoom button (THEMES.md §4.5). With
/// "URL in toolbar" off, back, forward and reload follow it and a URL field
/// that shows the page's domain and lock state sits below, opening the
/// command bar when clicked (COMMAND-BAR §2 placeholder). With it on (the
/// default), those live in the page card's toolbar strip instead.
struct SidebarToolbarView: View {
    let model: BrowserViewModel
    var urlInToolbar = ToolbarURLPreference.defaultValue
    @Environment(\.sidebarWindow) private var window
    @Environment(\.themeChrome) private var chrome

    /// The traffic lights' row: their centre is 23.5 pt from the top.
    static let rowHeight: CGFloat = 47

    var body: some View {
        let engine = model.focusedEngine(in: window)
        let profile = model.profile(in: window)
        let placement = model.sidebarPlacement
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                // Traffic lights, up to 12 pt past the zoom button; on the right they stay at the window's left.
                Spacer().frame(width: placement.trafficLightsInSidebar ? 84 : 10)
                Button { model.toggleSidebar() } label: {
                    Image(systemName: placement.side.toggleSymbol)
                        .font(.system(size: 14))
                        .foregroundStyle(chrome.glyph)
                        .frame(width: 19, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide Sidebar (⌘S)")
                .accessibilityLabel("Hide Sidebar")
                if !urlInToolbar {
                    Spacer(minLength: 4)
                    navButton("arrow.left", help: "Back (⌘[)", enabled: engine?.canGoBack == true) {
                        model.goBack()
                    }
                    navButton("arrow.right", help: "Forward (⌘])", enabled: engine?.canGoForward == true) {
                        model.goForward()
                    }
                    if engine?.isLoading == true {
                        navButton("xmark", help: "Stop Loading (⌘.)", enabled: true) { model.stopLoading() }
                    } else {
                        navButton("arrow.clockwise", help: "Reload (⌘R, ⇧⌘R ignores the cache)", enabled: engine != nil) {
                            model.reload(ignoringCache: NSEvent.modifierFlags.contains(.shift))
                        }
                    }
                    ExtensionToolbarView(model: model, engine: engine)
                }
                Spacer(minLength: 0)
                if model.store.profiles.count > 1 {
                    Menu {
                        Section("Switch to Profile") {
                            ProfileMenuChoices(store: model.store, active: profile.id) { model.selectProfile($0) }
                        }
                    } label: {
                        ProfileAvatarView(profile: profile, diameter: 18, sidebarBadge: chrome.badge)
                    }
                        // A plain button draws the badge as is (the borderless style dims it).
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Switch Profile: \(profile.name)")
                        .padding(.trailing, 10)
                        .help(profile.name)
                }
            }
            .frame(height: Self.rowHeight)

            if !urlInToolbar {
                SidebarURLField(model: model, engine: engine, tab: model.selectedTab(in: window))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
    }

    private func navButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? chrome.glyph : chrome.tertiaryText)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct SidebarURLField: View {
    let model: BrowserViewModel
    let engine: (any WebEngine)?
    let tab: Tab?
    @Environment(\.sidebarWindow) private var window
    @State private var isHovering = false
    @State private var showsSiteControls = false
    @State private var siteControlsAnchor: NSView?

    var body: some View {
        let url = engine?.currentURL ?? tab?.url
        let host = url.flatMap(Self.displayHost)
        let site = SiteControlCenter.site(for: url)
        HStack(spacing: 6) {
            if let engine, let site {
                // Arc's Site Control Center opens from the site's icon.
                Button { showsSiteControls.toggle() } label: {
                    securityIcon(engine.securityState, hasHost: true)
                        .frame(width: 16, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(AnchorReader { siteControlsAnchor = $0 })
                .help("Site controls for \(site.host)")
                .accessibilityLabel("Site controls")
                .popover(isPresented: $showsSiteControls, arrowEdge: .bottom) {
                    SiteControlCenterView(model: model, engine: engine, site: site, anchor: siteControlsAnchor) {
                        showsSiteControls = false
                    }
                }
            } else {
                securityIcon(engine?.securityState ?? .unknown, hasHost: host != nil)
            }
            Text(host ?? "Search or Enter URL…")
                .font(.system(size: 13))
                .foregroundStyle(host == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let summary = model.sitePermissionSummary(for: engine), site != nil {
                // The wave 22 indicator: answers recorded for this site.
                Button { showsSiteControls.toggle() } label: {
                    Image(systemName: summary.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(summary.anyBlocked ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Site permissions for \(summary.host)")
                .accessibilityLabel("Site permissions")
            }
        }
        .onChange(of: model.siteControlCenterRequest) { _, _ in
            if site != nil, model.isKeyBrowserWindow(window) { showsSiteControls = true }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(isHovering ? 0.10 : 0.06), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { model.focusLocation() }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy URL") { model.copyURL() }
                .disabled(tab == nil)
            Divider()
            Button("Show URL in Toolbar") { UserDefaults.standard.set(true, forKey: ToolbarURLPreference.key) }
        }
        .help(url?.absoluteString ?? "Open the command bar (⌘L)")
    }

    /// The domain, without `www.`; nil for blank pages.
    static func displayHost(_ url: URL) -> String? {
        if url.absoluteString == "about:blank" { return nil }
        guard let host = url.host(), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    @ViewBuilder
    private func securityIcon(_ state: WebSecurityState, hasHost: Bool) -> some View {
        switch state {
        case .secure:
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .help("Connection is secure")
        case .insecure:
            Image(systemName: "lock.open.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
                .help("Connection is not secure")
        case .dangerous:
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                .help("Dangerous site")
        case .none, .unknown:
            Image(systemName: hasHost ? "globe" : "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }
}
