import AppKit
import SecurityInterface
import SwiftUI
import SidebarModel

/// Engines that can count and clear a site's cookies and storage
/// (WebKit's data store). Chromium's live in its Site Settings page.
@MainActor
protocol SiteDataManaging: AnyObject {
    func siteDataKindCount(host: String) async -> Int
    func clearSiteData(host: String) async
}

/// Engines that hand over the page's server certificate (WebKit's
/// `serverTrust`). Chromium's engine ABI has none.
@MainActor
protocol ServerCertificateProviding: AnyObject {
    var serverTrust: SecTrust? { get }
}

extension BrowserViewModel {
    /// The site's boosts in the active profile, for the ⋯ menu's switches.
    func siteControlBoostRows(for url: URL) -> [SiteControlCenter.BoostRow] {
        guard BoostScopeMatcher.urlIsEligibleForBoosts(url) else { return [] }
        return SiteControlCenter.boostRows(store.boostsMatchingPage(url))
    }

    /// Zoom for the panel's page, whichever window it is in.
    func zoom(_ step: PageZoom.Step, engine: any WebEngine) {
        engine.setZoomFactor(PageZoom.factor(after: step, from: engine.zoomFactor))
    }

    /// The command bar's Site Controls: the key window's URL field opens its panel.
    func showSiteControlCenter() {
        siteControlCenterRequest += 1
    }

    /// The panel's Settings rows: answered permissions, then automatic PiP.
    func siteControlSettingRows(for engine: any WebEngine, site: SiteControlCenter.Site, now: Date = Date()) -> [SiteControlCenter.SettingRow] {
        SiteControlCenter.settingRows(
            permissions: sitePermissions.entries(origin: site.origin, scope: engine.pagePrompts.permissionScope),
            permissionsInEngine: sitePermissionsLiveInEngine,
            autoPiP: AutoPiPPolicy.effectiveHostPreference(host: Self.autoPiPHost(site), settings: store.autoPiPPolicy, now: now),
            autoPiPEnabled: automaticPictureInPicture,
            now: now
        )
    }

    /// Auto-PiP keys sites by the URL's own host, `www.` and all.
    static func autoPiPHost(_ site: SiteControlCenter.Site) -> String {
        URL(string: site.origin)?.host() ?? site.host
    }

    func performSiteSetting(_ action: SiteControlCenter.SettingAction, on row: SiteControlCenter.SettingRow,
                            engine: any WebEngine, site: SiteControlCenter.Site) {
        switch row.kind {
        case .autoPictureInPicture:
            let host = Self.autoPiPHost(site)
            switch action {
            case .allow: store.allowAutoPiP(forHost: host)
            case .block: store.setAutoPiPDisabled(forHost: host)
            case .snoozeOneHour: store.snoozeAutoPiP(forHost: host)
            case .reset, .openSiteSettings: break
            }
        case .permission(let key):
            let scope = engine.pagePrompts.permissionScope
            let type = PermissionType(key)
            switch action {
            case .allow, .block:
                let request = PermissionPromptRequest(id: 0, origin: site.origin, types: [type])
                sitePermissions.record(action == .allow ? .allow : .deny, remembered: true, request: request, scope: scope)
            case .reset:
                sitePermissions.reset(origin: site.origin, scope: scope, type: type)
            case .openSiteSettings:
                openSiteSettings(origin: site.origin)
            case .snoozeOneHour:
                break
            }
        }
    }

    func siteControlsMenu(for engine: any WebEngine, site: SiteControlCenter.Site) -> [[SiteControlCenter.MenuItem]] {
        SiteControlCenter.moreMenu(
            zoomPercent: PageZoom.percent(engine.zoomFactor),
            boosts: siteControlBoostRows(for: engine.currentURL ?? URL(string: site.origin)!),
            shellClearsSiteData: engine is SiteDataManaging,
            siteSettingsAvailable: sitePermissionsLiveInEngine
        )
    }

    func performSiteControlsMenuItem(_ item: SiteControlCenter.MenuItem, engine: any WebEngine, site: SiteControlCenter.Site) {
        switch item {
        case .zoomLevel: break
        case .zoomIn: zoom(.zoomIn, engine: engine)
        case .zoomOut: zoom(.zoomOut, engine: engine)
        case .actualSize: zoom(.reset, engine: engine)
        case .boost(let id, _, let enabled): setBoostEnabled(id, enabled: !enabled)
        case .editBoosts: editBoostFromTabContextMenu()
        case .clearSiteData:
            guard let manager = engine as? SiteDataManaging else { return }
            Task { @MainActor in
                await manager.clearSiteData(host: site.host)
                engine.reload()
            }
        case .cookiesAndSiteData, .siteSettings:
            openSiteSettings(origin: site.origin)
        }
    }

    @MainActor
    func siteControlsFooter(for engine: any WebEngine) -> SiteControlCenter.Footer {
        let connection: SiteControlCenter.Connection
        switch engine.securityState {
        case .secure: connection = .secure
        case .insecure: connection = .insecure
        case .dangerous: connection = .dangerous
        case .none, .unknown: connection = .unknown
        }
        let trust = (engine as? ServerCertificateProviding)?.serverTrust
        return SiteControlCenter.footer(connection, certificateAvailable: trust != nil, siteSettingsAvailable: sitePermissionsLiveInEngine)
    }
}

/// Arc's site controls popover from the toolbar (Arc `ARC_SiteControlCenter`):
/// Share, Boost, Capture and Capture Full Page; every extension, pinned ones
/// first with a pin badge; the site's settings; the connection and a ⋯ menu.
/// Built only while open: the toolbar reads none of this.
struct SiteControlCenterView: View {
    let model: BrowserViewModel
    let engine: any WebEngine
    let site: SiteControlCenter.Site
    /// The toolbar button: extension popups open under it once the panel closes.
    var anchor: NSView?
    let dismiss: () -> Void
    @Environment(\.sidebarWindow) private var window
    @Environment(\.colorScheme) private var colorScheme

    static let tile = CGSize(width: 48, height: 32)
    static let spacing: CGFloat = 8
    static let width = CGFloat(SiteControlCenter.extensionColumns) * tile.width + CGFloat(SiteControlCenter.extensionColumns - 1) * spacing

    private var url: URL { engine.currentURL ?? URL(string: site.origin)! }
    private var controller: ExtensionsController { model.extensions }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            quickActions
            if controller.isAvailable {
                header("Extensions")
                SiteControlsExtensionGrid(model: model, engine: engine) { id in
                    dismiss()
                    // The popup opens once the panel has closed.
                    DispatchQueue.main.async { controller.run(id, for: engine, anchor: anchor) }
                } add: {
                    dismiss()
                    model.openChromeWebStore()
                }
            }
            header("Settings")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.siteControlSettingRows(for: engine, site: site)) { row in
                    SiteControlsSettingRowView(row: row, isDark: colorScheme == .dark) { action in
                        if action == .openSiteSettings { dismiss() }
                        model.performSiteSetting(action, on: row, engine: engine, site: site)
                    }
                }
            }
            Divider().padding(.top, 10).padding(.bottom, 8)
            footer
        }
        .padding(10)
        .frame(width: Self.width + 20)
    }

    // MARK: Share, Boost, Capture

    private var quickActions: some View {
        HStack(spacing: Self.spacing) {
            ForEach(SiteControlCenter.quickActions(boostsEligible: BoostScopeMatcher.urlIsEligibleForBoosts(url))) { item in
                if item.action == .share {
                    ShareLink(item: url) { squareLabel(item.action) }
                        .buttonStyle(.plain)
                        .help(item.action.title)
                } else {
                    Button { run(item.action) } label: { squareLabel(item.action) }
                        .buttonStyle(.plain)
                        .disabled(!item.isEnabled)
                        .opacity(item.isEnabled ? 1 : 0.4)
                        .help(item.action.title)
                }
            }
        }
    }

    private func run(_ action: SiteControlCenter.QuickAction) {
        dismiss()
        switch action {
        case .share: break
        case .boost: model.newBoost()
        case .capture: _ = model.beginPageCapture(in: window)
        case .captureFullPage: Task { await model.performCapture(scope: .fullPage) }
        }
    }

    private func squareLabel(_ action: SiteControlCenter.QuickAction) -> some View {
        Image(systemName: action.symbol)
            .font(.system(size: 15))
            .foregroundStyle(.primary.opacity(0.8))
            .frame(width: Self.tile.width, height: Self.tile.height)
            .background(SiteControlsTileBackground(raised: true))
            .contentShape(Rectangle())
            .accessibilityLabel(action.title)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.75))
            .padding(.top, 14)
            .padding(.bottom, 8)
    }

    // MARK: Secure and ⋯

    private var footer: some View {
        let footer = model.siteControlsFooter(for: engine)
        return HStack {
            Button { open(footer.action) } label: {
                Label(footer.title, systemImage: footer.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(footer.isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary.opacity(0.85)))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(SiteControlsTileBackground(raised: false))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(footer.action == nil)
            .help(footer.action == .showCertificate ? "Show Certificate" : "Site Settings for \(site.host)")
            Spacer(minLength: 8)
            SiteControlsMoreButton(model: model, engine: engine, site: site, dismiss: dismiss)
        }
    }

    private func open(_ action: SiteControlCenter.FooterAction?) {
        switch action {
        case .showCertificate:
            guard let trust = (engine as? ServerCertificateProviding)?.serverTrust else { return }
            dismiss()
            DispatchQueue.main.async { SFCertificatePanel.shared()?.runModal(for: trust, showGroup: true) }
        case .openSiteSettings:
            dismiss()
            model.openSiteSettings(origin: site.origin)
        case nil:
            break
        }
    }
}

/// Arc's tiles: a light fill with a hairline; the top row's are raised (white).
private struct SiteControlsTileBackground: View {
    var raised: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let dark = colorScheme == .dark
        shape
            .fill(raised ? Color.white.opacity(dark ? 0.10 : 0.75) : Color.primary.opacity(dark ? 0.10 : 0.05))
            .overlay(shape.strokeBorder(Color.primary.opacity(raised ? 0.10 : 0), lineWidth: 0.5))
    }
}

/// The Extensions grid, four across; pinned extensions carry Arc's brown pin
/// badge and right-click pins or unpins. + opens the Chrome Web Store.
struct SiteControlsExtensionGrid: View {
    let model: BrowserViewModel
    let engine: (any WebEngine)?
    let run: (String) -> Void
    let add: () -> Void
    @Environment(\.displayScale) private var displayScale

    private let columns = Array(repeating: GridItem(.fixed(SiteControlCenterView.tile.width), spacing: SiteControlCenterView.spacing),
                                count: SiteControlCenter.extensionColumns)

    var body: some View {
        let controller = model.extensions
        LazyVGrid(columns: columns, alignment: .leading, spacing: SiteControlCenterView.spacing) {
            ForEach(SiteControlCenter.extensionTiles(controller.actions(for: engine), pins: controller.pins)) { tile in
                switch tile {
                case .action(let action, let pinned):
                    Button { run(action.id) } label: {
                        ExtensionIcon(action: action, size: 16)
                            .overlay(alignment: .bottomTrailing) {
                                if pinned { SiteControlsPinBadge().offset(x: 6, y: 5) }
                            }
                            .frame(width: SiteControlCenterView.tile.width, height: SiteControlCenterView.tile.height)
                            .background(SiteControlsTileBackground(raised: false))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!action.isEnabled)
                    .opacity(action.isEnabled ? 1 : 0.45)
                    .help(action.tooltip)
                    .accessibilityLabel(action.name)
                    .contextMenu {
                        Button(pinned ? "Unpin \(action.name)" : "Pin \(action.name)") { controller.togglePin(action.id) }
                    }
                case .add:
                    Button(action: add) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.7))
                            .frame(width: SiteControlCenterView.tile.width, height: SiteControlCenterView.tile.height)
                            .background(SiteControlsTileBackground(raised: false))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Chrome Web Store")
                    .accessibilityLabel("Add Extensions")
                    .contextMenu { Button("Manage Extensions") { model.openBrowserPage(.extensions) } }
                }
            }
        }
        // The list is the tab's last answer. Asked again on opening, so an
        // extension that loaded after the tab first asked shows up (QA 2026-11-08 #20).
        .task { controller.refresh(engine, scale: displayScale) }
    }
}

/// Arc's pin badge: a small brown disc with a white pin.
struct SiteControlsPinBadge: View {
    static let fill = Color(.sRGB, red: 0.42, green: 0.33, blue: 0.27)

    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 6.5, weight: .bold))
            .rotationEffect(.degrees(45))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .background(Self.fill, in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
    }
}

/// A Settings row: Arc's round taupe icon, the title and the site's state.
/// One action is the click; more open a menu under the row.
private struct SiteControlsSettingRowView: View {
    let row: SiteControlCenter.SettingRow
    let isDark: Bool
    let perform: (SiteControlCenter.SettingAction) -> Void
    @State private var anchor: NSView?
    @State private var isHovering = false

    private static let disc = Color(.sRGB, red: 0.80, green: 0.76, blue: 0.72)

    var body: some View {
        Button(action: click) {
            HStack(spacing: 10) {
                Image(systemName: row.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(isDark ? Color.white.opacity(0.22) : Self.disc, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(row.state)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(Color.primary.opacity(isHovering && !row.actions.isEmpty ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -4)
        .disabled(row.actions.isEmpty)
        .background(AnchorReader { anchor = $0 })
        .onHover { isHovering = $0 }
        .help(row.actions.count == 1 ? row.actions[0].title : "\(row.title): \(row.state)")
        .accessibilityLabel("\(row.title), \(row.state)")
    }

    private func click() {
        if row.actions.count == 1 { return perform(row.actions[0]) }
        let menu = NSMenu()
        for action in row.actions {
            menu.addItem(ClosureMenuItem(action.title) { perform(action) })
        }
        popUp(menu, under: anchor)
    }
}

/// Arc's ⋯ at the footer's right: zoom, the site's boosts, cookies and site data, Site Settings.
private struct SiteControlsMoreButton: View {
    let model: BrowserViewModel
    let engine: any WebEngine
    let site: SiteControlCenter.Site
    let dismiss: () -> Void
    @State private var anchor: NSView?

    var body: some View {
        Button(action: showMenu) {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(AnchorReader { anchor = $0 })
        .help("More Site Controls")
        .accessibilityLabel("More Site Controls")
    }

    /// Built at the click, so the panel observes none of it.
    private func showMenu() {
        let menu = NSMenu()
        for (index, section) in model.siteControlsMenu(for: engine, site: site).enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in section {
                let entry = ClosureMenuItem(item.title) { [model, engine, site, dismiss] in
                    switch item {
                    case .editBoosts, .cookiesAndSiteData, .siteSettings: dismiss()
                    default: break
                    }
                    model.performSiteControlsMenuItem(item, engine: engine, site: site)
                }
                switch item {
                case .zoomLevel: entry.isEnabled = false
                case .actualSize(let enabled): entry.isEnabled = enabled
                case .boost(_, _, let enabled): entry.state = enabled ? .on : .off
                default: break
                }
                menu.addItem(entry)
            }
        }
        menu.autoenablesItems = false
        popUp(menu, under: anchor)
    }
}

/// Pops a menu just below `view`.
private func popUp(_ menu: NSMenu, under view: NSView?) {
    guard let view else { return }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
}
