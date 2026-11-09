import AppKit
import SidebarModel
import SwiftUI

/// The import window: sources on the left (Arc's sidebar, then each
/// Arc, Chrome and Brave profile), what comes over on the right, Import at
/// the bottom. Its controller is the same on both engines.
final class BrowserImportWindowController: NSWindowController, NSWindowDelegate {
    let session: BrowserImportSession

    init(session: BrowserImportSession) {
        self.session = session
        let hosting = NSHostingController(rootView: BrowserImportView(session: session))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Import"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 540))
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if !window.setFrameUsingName("ReArcImport") { window.center() }
        window.setFrameAutosaveName("ReArcImport")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Each opening looks again (counts change as the other browser runs);
    /// bringing an open window forward keeps the choices made in it.
    override func showWindow(_ sender: Any?) {
        let wasVisible = window?.isVisible ?? false
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !wasVisible { session.discover() }
    }
}

struct BrowserImportView: View {
    @Bindable var session: BrowserImportSession
    /// The list's own selection, mirrored to the session. Bound straight to
    /// the session, the first click after the window opened set it without
    /// redrawing the pane beside the list: the row highlighted over the old
    /// pane until it was clicked again (QA-483 B9).
    @State private var selection: BrowserImportSession.Source?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sourceList
                    .frame(width: 220)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .onAppear { selection = session.selection }
        .onChange(of: selection) { _, new in if session.selection != new { session.selection = new } }
        .onChange(of: session.selection) { _, new in if selection != new { selection = new } }
    }

    // MARK: Sources

    private var sourceList: some View {
        List(selection: $selection) {
            if session.isDiscovering && session.browsers.isEmpty {
                ProgressView().controlSize(.small)
            }
            ForEach(ImportBrowser.allCases) { browser in
                let sources = session.sources.filter { source in
                    switch source {
                    case .arcSidebar: return browser == .arc
                    case .profile(let profile): return profile.browser == browser
                    }
                }
                if !sources.isEmpty {
                    Section(browser.name) {
                        ForEach(sources, id: \.self) { source in
                            sourceRow(source).tag(source)
                        }
                    }
                }
            }
            if !session.isDiscovering && session.sources.isEmpty {
                Text("No Arc, Chrome or Brave data was found on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(session.unreadableBrowsers) { browser in
                Label("\(browser.name): allow ReArc in System Settings › Privacy & Security › Full Disk Access",
                      systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func sourceRow(_ source: BrowserImportSession.Source) -> some View {
        switch source {
        case .arcSidebar:
            Label("Spaces & Sidebar", systemImage: "sidebar.left")
        case .profile(let profile):
            Label(profile.name, systemImage: "person.crop.circle")
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .arcSidebar:
            ArcSidebarImportPane(session: session)
        case .profile(let profile):
            if let detail = session.detail(for: profile) {
                ChromiumProfileImportPane(session: session, profile: profile, detail: detail)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case nil:
            Text(session.isDiscovering ? "Looking for browsers…" : "Choose what to import.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let result = session.result {
                Label(result, systemImage: "checkmark.circle").foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if session.isImporting { ProgressView().controlSize(.small) }
            Button(session.isUpToDate ? "Imported" : "Import") { session.performImport() }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canImport)
        }
        .padding(12)
    }
}

/// Arc's spaces with a checkbox each, grouped by Arc profile, with where
/// each profile goes, plus favorites, Today tabs and Arc's settings.
private struct ArcSidebarImportPane: View {
    @Bindable var session: BrowserImportSession

    var body: some View {
        if let arc = session.arc {
            Form {
                Section {
                    Text(summaryLine).font(.headline)
                    Text("Each space comes over as a new space. Nothing in Arc changes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(arc.export.profiles, id: \.self) { profile in
                    let spaces = arc.spaces(in: profile)
                    Section {
                        profileTarget(profile, name: arc.name(of: profile))
                        ForEach(spaces) { space in
                            let imported = session.isImported(space)
                            Toggle(isOn: Binding(get: { session.arcChoices.spaceIDs.contains(space.id) },
                                                 set: { session.setSpace(space.id, included: $0) })) {
                                HStack(spacing: 8) {
                                    spaceIcon(space)
                                    Text(space.name)
                                    Spacer()
                                    Text(imported ? "Imported" : spaceCounts(space)).foregroundStyle(.secondary).font(.callout)
                                }
                            }
                            // Already here: importing it again would add only what is new in Arc.
                            .disabled(imported && session.arcSummary.isEmpty)
                        }
                    } header: {
                        Text("Arc profile \u{201C}\(arc.name(of: profile))\u{201D}")
                    }
                }
                Section {
                    SettingsToggleRow(label: "Favorites", detail: "\(favoriteCount(arc)) across your Arc profiles",
                                      isOn: $session.arcChoices.includeFavorites)
                    SettingsToggleRow(label: "Today tabs", detail: "\(arc.export.spaces.reduce(0) { $0 + $1.todayTabCount }) unpinned tabs; Arc archives these on its own",
                                      isOn: $session.arcChoices.includeToday)
                    if session.arcSettings.count > 0 {
                        SettingsToggleRow(label: "Arc settings", detail: settingsDetail, isOn: $session.includeArcSettings)
                    }
                    if let card = session.arcCard {
                        SettingsToggleRow(label: "Membership card", detail: cardDetail(card), isOn: $session.includeArcCard)
                    }
                }
                Section("Not imported") {
                    Text(droppedText(arc.export.dropped))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } else {
            Text(session.arcProblem ?? "Reading Arc's sidebar…")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var summaryLine: String { session.arcHeadline }

    /// Its title and member-since date: the card in Settings › Account.
    private func cardDetail(_ card: ArcMembershipCardImport) -> String {
        var parts: [String] = []
        if let title = card.title { parts.append(title.capitalized) }
        if let since = card.memberSince { parts.append("Arc since \(MembershipCardDates.format(since))") }
        return parts.isEmpty ? "Settings › Account" : parts.joined(separator: ", ") + "; in Settings › Account"
    }

    private var settingsDetail: String {
        let settings = session.arcSettings
        var names: [String] = []
        if settings.warnBeforeQuitting != nil { names.append("warn before quitting") }
        if settings.restoreWindows != nil { names.append("reopen windows") }
        if settings.externalLinkDestination != nil { names.append("external links") }
        if settings.autoArchive != nil { names.append("archive tabs after") }
        if settings.littleArcArchive != nil { names.append("archive Little Arcs after") }
        return names.joined(separator: ", ").capitalizedFirst
    }

    private func favoriteCount(_ arc: ArcSidebarImport) -> Int {
        arc.export.favorites.values.reduce(0) { $0 + $1.count }
    }

    private func spaceCounts(_ space: ArcSidebarSpace) -> String {
        var text = "\(space.pinnedTabCount) pinned"
        if space.folderCount > 0 { text += ", \(space.folderCount) folder\(space.folderCount == 1 ? "" : "s")" }
        return text
    }

    @ViewBuilder
    private func spaceIcon(_ space: ArcSidebarSpace) -> some View {
        if let icon = space.icon, Space.isSymbolName(icon) {
            Image(systemName: icon).frame(width: 18)
        } else if let icon = space.icon {
            Text(icon).frame(width: 18)
        } else {
            Image(systemName: "circle.fill").font(.system(size: 8)).frame(width: 18).foregroundStyle(.secondary)
        }
    }

    private func profileTarget(_ profile: ArcProfileRef, name: String) -> some View {
        SettingsRow(label: "Into") {
            Picker("Into", selection: Binding(
                get: { session.arcChoices.profileTargets[profile] ?? .newProfile },
                set: { session.arcChoices.profileTargets[profile] = $0 }
            )) {
                ForEach(session.reArcProfiles) { existing in
                    Text("ReArc profile \u{201C}\(existing.name)\u{201D}").tag(ArcProfileTarget.existing(existing.id))
                }
                Text("New profile \u{201C}\(name)\u{201D}").tag(ArcProfileTarget.newProfile)
            }
            .labelsHidden().fixedSize()
        }
    }

    private func droppedText(_ dropped: ArcSidebarDropped) -> String {
        var lines: [String] = []
        if dropped.easels > 0 { lines.append("\(dropped.easels) easel\(dropped.easels == 1 ? "" : "s"): their content is in Arc's cloud, not on this Mac.") }
        if dropped.nonWebTabs > 0 { lines.append("\(dropped.nonWebTabs) tab\(dropped.nonWebTabs == 1 ? "" : "s") that are not web pages (Arc's own pages, files).") }
        if dropped.splitsFlattened > 0 { lines.append("\(dropped.splitsFlattened) split view\(dropped.splitsFlattened == 1 ? "" : "s") inside folders come over as their tabs.") }
        lines.append("The Archive, Boosts, Little Arc windows, sign-ins and site data stay in Arc. Choose an Arc profile on the left for its history and extensions.")
        return lines.joined(separator: "\n")
    }
}

/// A Chrome, Brave or Arc profile: bookmarks, history, search engine and
/// extensions, into a chosen ReArc profile. Passwords, cookies and autofill
/// wait for the consent step (PROFILE-IMPORT §2.3).
private struct ChromiumProfileImportPane: View {
    @Bindable var session: BrowserImportSession
    let profile: ImportSourceProfile
    let detail: BrowserImportSession.ProfileDetail

    var body: some View {
        Form {
            Section {
                Text("\(profile.browser.name) \u{2014} \(profile.name)").font(.headline)
                SettingsRow(label: "Into ReArc profile") {
                    Picker("Into ReArc profile", selection: $session.targetProfileID) {
                        ForEach(session.reArcProfiles) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Section {
                let plan = session.bookmarkPlan(for: profile, detail)
                SettingsToggleRow(label: "Bookmarks", detail: bookmarksDetail(plan), isOn: $session.includeBookmarks)
                    .disabled(plan.isEmpty)
                SettingsToggleRow(label: "History", detail: historyDetail, isOn: $session.includeHistory)
                    .disabled((detail.newHistoryPages ?? 0) == 0)
                if let engine = detail.setup.searchEngine {
                    let isNew = session.newSearchEngine(detail) != nil
                    SettingsToggleRow(label: "Search engine", detail: isNew ? "\(engine.name), if ReArc offers it" : "\(engine.name): already the default, or not offered",
                                      isOn: $session.includeSearchEngine)
                        .disabled(!isNew)
                }
            }
            extensionsSection
            Section("Needs your approval") {
                Text(secretsText).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func bookmarksDetail(_ plan: BookmarkImportPlan) -> String {
        if plan.isEmpty {
            if plan.mirrorsArcSidebar { return "Already in your spaces from Arc's sidebar" }
            return plan.existingSpaceID != nil ? "Imported" : "None"
        }
        if plan.existingSpaceID != nil, let space = plan.existingSpaceID.flatMap(session.spaceName) {
            return "\(plan.newLinks) new, into \(space)"
        }
        return "\(plan.newLinks) as a new space of pinned tabs and folders"
    }

    private var historyDetail: String {
        guard let pages = detail.newHistoryPages else { return "Not readable" }
        if pages == 0 { return (detail.inventory.historyPages ?? 0) > 0 ? "Imported" : "None" }
        let new = detail.newHistoryPages == detail.inventory.historyPages ? "most recent pages" : "pages visited since the last import"
        return "\(min(pages, VisitHistory.capacity)) \(new), for command bar suggestions"
    }

    @ViewBuilder
    private var extensionsSection: some View {
        if !detail.extensions.isEmpty {
            Section {
                SettingsToggleRow(label: "Extensions", detail: extensionsDetail, isOn: $session.includeExtensions)
                    .disabled(!session.canReinstallExtensions)
                let installable = Set(session.installableExtensions(detail).map(\.id))
                ForEach(detail.extensions) { item in
                    let installed = detail.installedExtensionIDs.contains(item.id)
                    let eligible = installable.contains(item.id)
                    Toggle(isOn: Binding(get: { eligible && !session.skippedExtensions.contains(item.id) },
                                         set: { if $0 { session.skippedExtensions.remove(item.id) } else { session.skippedExtensions.insert(item.id) } })) {
                        HStack {
                            Text(item.name)
                            if item.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(installed ? "installed" : extensionNote(item)).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!eligible || !session.includeExtensions || !session.canReinstallExtensions)
                }
            }
        }
    }

    private var extensionsDetail: String {
        guard session.canReinstallExtensions else { return "Reinstalling extensions needs the Chromium engine" }
        return "Installed from the Chrome Web Store; their settings stay in \(profile.browser.name)"
    }

    private func extensionNote(_ item: SourceExtension) -> String {
        var notes: [String] = []
        switch item.origin {
        case .webStore: notes.append("Web Store")
        case .unpacked(let path): notes.append(item.canReinstall ? "unpacked" : "folder missing: \((path as NSString).lastPathComponent)")
        case .other: notes.append("installed by another app or policy")
        }
        if !item.isEnabled { notes.append("off") }
        if item.isTheme { notes.append("theme") }
        return notes.joined(separator: ", ")
    }

    private var secretsText: String {
        var kinds: [String] = []
        if detail.inventory.hasPasswords { kinds.append("passwords") }
        if detail.inventory.hasCookies { kinds.append("sign-ins (cookies)") }
        if detail.inventory.hasAutofill { kinds.append("autofill") }
        let what = kinds.isEmpty ? "Passwords and sign-ins" : kinds.joined(separator: ", ").capitalizedFirst
        return "\(what) are encrypted with \u{201C}\(profile.browser.safeStorageService)\u{201D} in your keychain. "
            + "Importing them will ask your permission first, for this browser only; it is not available yet. "
            + "Until then, export passwords from \(profile.browser.name) as a CSV file and import it in Settings › Passwords."
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
