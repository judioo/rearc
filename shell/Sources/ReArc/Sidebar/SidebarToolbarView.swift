import SwiftUI
import SidebarModel

/// Arc has no toolbar: back, forward and reload sit at the top of the
/// sidebar beside the traffic lights, above a URL field that shows the
/// page's domain and lock state and opens the command bar when clicked
/// (COMMAND-BAR §2 placeholder). State follows the selected tab's engine.
struct SidebarToolbarView: View {
    let model: BrowserViewModel
    @Environment(\.sidebarWindow) private var window

    var body: some View {
        let engine = model.focusedEngine(in: window)
        let profile = model.profile(in: window)
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                Spacer(minLength: 72) // traffic lights
                navButton("chevron.left", help: "Back (⌘[)", enabled: engine?.canGoBack == true) {
                    model.goBack()
                }
                navButton("chevron.right", help: "Forward (⌘])", enabled: engine?.canGoForward == true) {
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
                ProfileAvatarView(profile: profile, diameter: 18)
                    .opacity(0.85)
                    .padding(.leading, 4)
                    .help(profile.name)
            }
            .frame(height: 22)

            SidebarURLField(model: model, engine: engine, tab: model.selectedTab(in: window))
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
    }

    private func navButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
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
                .help("Site controls for \(site.host)")
                .accessibilityLabel("Site controls")
                .popover(isPresented: $showsSiteControls, arrowEdge: .bottom) {
                    SiteControlCenterView(model: model, engine: engine, site: site) { showsSiteControls = false }
                }
            } else {
                securityIcon(engine?.securityState ?? .unknown, hasHost: host != nil)
            }
            Text(host ?? "Search or Enter URL…")
                .font(.callout)
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
