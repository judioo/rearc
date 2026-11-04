import SwiftUI
import SidebarModel

/// Engines that can count and clear a site's cookies and storage
/// (WebKit's data store). Chromium's live in its Site Settings page.
@MainActor
protocol SiteDataManaging: AnyObject {
    func siteDataKindCount(host: String) async -> Int
    func clearSiteData(host: String) async
}

extension BrowserViewModel {
    /// The site's boosts in the active profile, for the panel's switches.
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
}

/// Arc's Site Control Center: one panel per site from the URL field.
struct SiteControlCenterView: View {
    let model: BrowserViewModel
    let engine: any WebEngine
    let site: SiteControlCenter.Site
    let dismiss: () -> Void

    @State private var siteDataKinds: Int?
    @State private var isClearing = false

    private var url: URL { engine.currentURL ?? URL(string: site.origin)! }
    private var engineOwnsSettings: Bool { model.sitePermissionsLiveInEngine }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            permissions
            Divider()
            boosts
            Divider()
            zoom
            Divider()
            siteData
        }
        .padding(14)
        .frame(width: 300)
        .task(id: site.host) { await refreshSiteData() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(site.host).font(.headline)
            Label(connectionText, systemImage: connectionSymbol)
                .font(.caption)
                .foregroundStyle(engine.securityState == .insecure || engine.securityState == .dangerous ? Color.orange : Color.secondary)
        }
    }

    private var connectionText: String {
        switch engine.securityState {
        case .secure: return "Connection is secure"
        case .insecure: return "Connection is not secure"
        case .dangerous: return "This site may be dangerous"
        case .none, .unknown: return "Connection details unavailable"
        }
    }

    private var connectionSymbol: String {
        switch engine.securityState {
        case .secure: return "lock.fill"
        case .insecure: return "lock.open.fill"
        case .dangerous: return "exclamationmark.octagon.fill"
        case .none, .unknown: return "globe"
        }
    }

    // MARK: Permissions (wave 22 answers)

    @ViewBuilder
    private var permissions: some View {
        let summary = model.sitePermissionSummary(for: engine)
        section("Permissions") {
            if let summary {
                ForEach(summary.rows, id: \.type.key) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.type.symbol).frame(width: 18).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.type.name).font(.system(size: 13))
                            Text(statusText(row.entry))
                                .font(.caption)
                                .foregroundStyle(row.entry.decision == .deny ? Color.orange : Color.secondary)
                        }
                        Spacer(minLength: 12)
                        if !engineOwnsSettings {
                            Button("Reset") {
                                model.sitePermissions.reset(origin: summary.origin, scope: summary.scope, type: row.type)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                if !engineOwnsSettings {
                    Button("Reset All Permissions") {
                        model.sitePermissions.reset(origin: summary.origin, scope: summary.scope)
                    }
                    .controlSize(.small)
                }
            } else {
                Text("This site has not asked for any permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if engineOwnsSettings {
                Button("Site Settings…") {
                    dismiss()
                    model.openSiteSettings(origin: site.origin)
                }
                .controlSize(.small)
                .help("Chromium keeps remembered permissions; change them in its site settings")
            }
        }
    }

    private func statusText(_ entry: SitePermissionStore.Entry) -> String {
        let decision = entry.decision == .allow ? "Allowed" : "Blocked"
        return entry.remembered ? decision : "\(decision) this time"
    }

    // MARK: Boosts

    @ViewBuilder
    private var boosts: some View {
        let rows = model.siteControlBoostRows(for: url)
        section("Boosts") {
            ForEach(rows) { row in
                HStack {
                    Text(row.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Toggle(row.name, isOn: Binding(
                        get: { row.isEnabled },
                        set: { model.setBoostEnabled(row.id, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
            if rows.isEmpty {
                Text(BoostScopeMatcher.urlIsEligibleForBoosts(url) ? "No boosts for this site." : "Boosts cannot change this page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if BoostScopeMatcher.urlIsEligibleForBoosts(url) {
                HStack {
                    Button("New Boost") {
                        dismiss()
                        model.newBoost()
                    }
                    if !rows.isEmpty {
                        Button("Edit…") {
                            dismiss()
                            model.editBoostFromTabContextMenu()
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Zoom

    private var zoom: some View {
        section("Zoom") {
            HStack(spacing: 8) {
                Button { model.zoom(.zoomOut, engine: engine) } label: { Image(systemName: "minus").frame(width: 14, height: 14) }
                    .help("Zoom Out (⌘-)")
                Text("\(PageZoom.percent(engine.zoomFactor))%")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 48)
                Button { model.zoom(.zoomIn, engine: engine) } label: { Image(systemName: "plus").frame(width: 14, height: 14) }
                    .help("Zoom In (⌘=)")
                Spacer()
                Button("Reset") { model.zoom(.reset, engine: engine) }
                    .disabled(PageZoom.isDefault(engine.zoomFactor))
                    .help("Actual Size (⌘0)")
            }
            .controlSize(.small)
        }
    }

    // MARK: Cookies and site data

    private var siteData: some View {
        section("Cookies and Site Data") {
            if let manager = engine as? SiteDataManaging {
                Text(SiteControlCenter.siteDataSummary(recordCount: siteDataKinds ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(isClearing ? "Clearing…" : "Clear Site Data") {
                    isClearing = true
                    Task { @MainActor in
                        await manager.clearSiteData(host: site.host)
                        isClearing = false
                        await refreshSiteData()
                        engine.reload()
                    }
                }
                .controlSize(.small)
                .disabled(isClearing || siteDataKinds == 0)
                .help("Removes this site's cookies and storage, then reloads the page")
            } else {
                Text(SiteControlCenter.siteDataSummary(recordCount: nil))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cookies and Site Data…") {
                    dismiss()
                    model.openSiteSettings(origin: site.origin)
                }
                .controlSize(.small)
                .disabled(!engineOwnsSettings)
                .help("Opens Chromium's page for this site, where its cookies and storage can be seen and cleared")
            }
        }
    }

    private func refreshSiteData() async {
        guard let manager = engine as? SiteDataManaging else { return }
        siteDataKinds = await manager.siteDataKindCount(host: site.host)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }
}
