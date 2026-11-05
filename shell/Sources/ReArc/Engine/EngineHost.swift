import Foundation
import SidebarModel

/// Owns one engine instance per tab and profile context, created lazily.
@Observable
final class EngineHost {
    struct TabEngineKey: Hashable {
        let tabID: Tab.ID
        let profileID: Profile.ID
    }

    struct EphemeralEngineKey: Hashable {
        let id: UUID
        let profileID: Profile.ID
    }

    struct LittleArcEngineKey: Hashable {
        let id: UUID
        let profileID: Profile.ID
    }

    /// Observed per key (`engineCells`): creating or dropping one tab's
    /// engine notifies the views that looked that tab up, not every row.
    @ObservationIgnored private var engines: [TabEngineKey: any WebEngine] = [:]
    private enum EngineCell: Hashable {
        case tab(TabEngineKey)
        case allTabs
    }
    @ObservationIgnored private let engineCells = ObservationCells<EngineCell>()
    private var ephemeralEngines: [EphemeralEngineKey: any WebEngine] = [:]
    private var littleArcEngines: [LittleArcEngineKey: any WebEngine] = [:]
    /// WebKit engines hand their downloads to the tray (Chromium reports its own).
    @ObservationIgnored weak var downloadCenter: WebKitDownloadCenter?
    /// Where page prompts open links (the browser view model).
    @ObservationIgnored weak var linkRouter: PageLinkRouting?
    /// Permission answers, for the URL field indicator and WebKit's remembered answers.
    @ObservationIgnored weak var sitePermissions: SitePermissionsController?

    /// Favorites are global in the sidebar, but each favorite tab's engine uses
    /// the **active** profile's storage at load time (see `BrowserViewModel.profileID(for:)`).
    func engine(for tab: Tab, profileID: Profile.ID) -> any WebEngine {
        let key = TabEngineKey(tabID: tab.id, profileID: profileID)
        defer { engineCells.access(.tab(key)) }
        if let existing = engines[key] { return existing }
        let context = EngineProfileContext(profileID: profileID)
        let created = makeEngine(context: context, role: .tab, shellID: tab.id)
        setTabEngine(created, for: key)
        return created
    }

    private func setTabEngine(_ engine: (any WebEngine)?, for key: TabEngineKey) {
        engines[key] = engine
        engineCells.invalidate(.tab(key))
        engineCells.invalidate(.allTabs)
    }

    /// Drops the tab engines `remove` picks, in place; nothing is notified when none goes.
    private func removeTabEngines(where remove: (TabEngineKey) -> Bool) {
        let doomed = engines.keys.filter(remove)
        guard !doomed.isEmpty else { return }
        for key in doomed { setTabEngine(nil, for: key) }
    }

    /// The single place that picks the concrete engine type.
    ///
    /// Storage follows `EngineProfileContext` on both engines: WKEngine keeps
    /// one `WKWebsiteDataStore` per profile (non-persistent when ephemeral), and
    /// ChromiumEngine opens one named engine profile per shell profile, or an
    /// off-the-record profile for an ephemeral context (`ChromiumProfileKey`).
    /// `privateSession` groups the engines of one private browsing session
    /// into one off-the-record context (Chromium; WebKit gives each ephemeral
    /// engine its own non-persistent store).
    private func makeEngine(
        context: EngineProfileContext,
        role: EngineRole,
        shellID: UUID,
        privateSession: UUID? = nil
    ) -> any WebEngine {
        let engine = makeConcreteEngine(context: context, role: role, shellID: shellID, privateSession: privateSession)
        let prompts = engine.pagePrompts
        prompts.role = role
        prompts.ownerTabID = role == .tab ? shellID : nil
        prompts.profileID = context.profileID
        prompts.privateSession = context.isEphemeral ? (privateSession ?? shellID) : nil
        prompts.router = linkRouter
        prompts.sitePermissions = sitePermissions
        return engine
    }

    private func makeConcreteEngine(
        context: EngineProfileContext,
        role: EngineRole,
        shellID: UUID,
        privateSession: UUID?
    ) -> any WebEngine {
        #if REARC_CHROMIUM
        if let runtime = ChromiumRuntime.active {
            return ChromiumEngine(runtime: runtime, context: context, role: role, shellID: shellID, privateSession: privateSession)
        }
        #endif
        let engine = WKEngine(context: context)
        engine.downloadCenter = downloadCenter
        return engine
    }

    /// Engine for a private window. Not cached: the window owns it, and its
    /// storage is off the record under `parentProfileID`.
    func privateEngine(session: UUID, parentProfileID: Profile.ID, shellID: UUID) -> any WebEngine {
        let context = EngineProfileContext(profileID: parentProfileID, isEphemeral: true)
        return makeEngine(context: context, role: .privateWindow, shellID: shellID, privateSession: session)
    }

    /// URLs the running engine admits beyond the base set; Chromium WebUI and
    /// view-source need ABI 1.5 with `navigation_extended`.
    var navigationSchemes: NavigationURLPolicy.EngineSchemes {
        #if REARC_CHROMIUM
        if let runtime = ChromiumRuntime.active {
            return runtime.capabilities.navigationSchemes
        }
        #endif
        return []
    }

    /// PiP video plays in shell views (Chromium `pip_embedded`, ABI 1.43).
    var supportsLiveVideo: Bool {
        #if REARC_CHROMIUM
        return ChromiumRuntime.active?.capabilities.pipEmbedded ?? false
        #else
        return false
        #endif
    }

    /// Binds an engine the shell did not create (a Chromium-created tab) to a sidebar tab.
    func adopt(_ engine: any WebEngine, for tab: Tab, profileID: Profile.ID) {
        let prompts = engine.pagePrompts
        prompts.role = .tab
        prompts.ownerTabID = tab.id
        prompts.profileID = profileID
        prompts.router = linkRouter
        prompts.sitePermissions = sitePermissions
        setTabEngine(engine, for: TabEngineKey(tabID: tab.id, profileID: profileID))
    }

    /// Prompt identity for an engine made outside `makeEngine` (an adopted private-window popup).
    func configurePrompts(of engine: any WebEngine, role: EngineRole, profileID: Profile.ID, privateSession: UUID?) {
        let prompts = engine.pagePrompts
        prompts.role = role
        prompts.ownerTabID = nil
        prompts.profileID = profileID
        prompts.privateSession = privateSession
        prompts.router = linkRouter
        prompts.sitePermissions = sitePermissions
    }

    func engine(forTabID id: Tab.ID, profileID: Profile.ID) -> (any WebEngine)? {
        let key = TabEngineKey(tabID: id, profileID: profileID)
        engineCells.access(.tab(key))
        return engines[key]
    }

    func allTabEngines() -> [(Tab.ID, Profile.ID, any WebEngine)] {
        engineCells.access(.allTabs)
        return engines.map { (key, engine) in (key.tabID, key.profileID, engine) }
    }

    /// Drops cached engines for the given tab ids (all profile contexts).
    func evictEngines(forTabIDs ids: [Tab.ID]) {
        let idSet = Set(ids)
        removeTabEngines { idSet.contains($0.tabID) }
    }

    /// Drops every engine (tabs, peeks, Little Arc) that used the given profile.
    func evictEngines(forProfileID id: Profile.ID) {
        removeTabEngines { $0.profileID == id }
        if ephemeralEngines.keys.contains(where: { $0.profileID == id }) {
            ephemeralEngines = ephemeralEngines.filter { $0.key.profileID != id }
        }
        if littleArcEngines.keys.contains(where: { $0.profileID == id }) {
            littleArcEngines = littleArcEngines.filter { $0.key.profileID != id }
        }
    }

    /// Removes tab engines whose tab/profile pair is not in the live sidebar
    /// ownership set. Nothing changes (or is notified) when all are live.
    func pruneTabEngines(retaining keys: Set<TabEngineKey>) {
        removeTabEngines { !keys.contains($0) }
    }

    func pruneLittleArcEngines(retaining keys: Set<LittleArcEngineKey>) {
        guard littleArcEngines.keys.contains(where: { !keys.contains($0) }) else { return }
        littleArcEngines = littleArcEngines.filter { keys.contains($0.key) }
    }

    func pruneEphemeralEngines(retaining keys: Set<EphemeralEngineKey>) {
        guard ephemeralEngines.keys.contains(where: { !keys.contains($0) }) else { return }
        ephemeralEngines = ephemeralEngines.filter { keys.contains($0.key) }
    }

    /// Ephemeral engine for peek overlays; discarded when the peek closes.
    func ephemeralEngine(profileID: Profile.ID) -> (id: UUID, engine: any WebEngine) {
        let id = UUID()
        let context = EngineProfileContext(profileID: profileID)
        let engine = makeEngine(context: context, role: .peek, shellID: id)
        ephemeralEngines[EphemeralEngineKey(id: id, profileID: profileID)] = engine
        return (id, engine)
    }

    func ephemeralEngine(withID id: UUID, profileID: Profile.ID) -> (any WebEngine)? {
        ephemeralEngines[EphemeralEngineKey(id: id, profileID: profileID)]
    }

    func removeEphemeral(id: UUID, profileID: Profile.ID) {
        ephemeralEngines[EphemeralEngineKey(id: id, profileID: profileID)] = nil
    }

    func remove(_ id: Tab.ID) {
        removeTabEngines { $0.tabID == id }
    }

    func engine(forLittleArc id: UUID, profileID: Profile.ID) -> any WebEngine {
        let key = LittleArcEngineKey(id: id, profileID: profileID)
        if let existing = littleArcEngines[key] { return existing }
        let context = EngineProfileContext(profileID: profileID)
        let created = makeEngine(context: context, role: .littleArc, shellID: id)
        littleArcEngines[key] = created
        return created
    }

    func existingLittleArcEngine(_ id: UUID, profileID: Profile.ID) -> (any WebEngine)? {
        littleArcEngines[LittleArcEngineKey(id: id, profileID: profileID)]
    }

    /// Chromium-created contents opened by ⌥⌘-click become a Little Arc's page.
    func adoptLittleArc(_ engine: any WebEngine, id: UUID, profileID: Profile.ID) {
        let prompts = engine.pagePrompts
        prompts.role = .littleArc
        prompts.ownerTabID = nil
        prompts.profileID = profileID
        prompts.router = linkRouter
        prompts.sitePermissions = sitePermissions
        littleArcEngines[LittleArcEngineKey(id: id, profileID: profileID)] = engine
    }

    func removeLittleArc(_ id: UUID, profileID: Profile.ID) {
        littleArcEngines[LittleArcEngineKey(id: id, profileID: profileID)] = nil
    }

    func setMuted(_ muted: Bool, forTabID id: Tab.ID, profileID: Profile.ID) {
        engines[TabEngineKey(tabID: id, profileID: profileID)]?.setMuted(muted)
    }

    func pauseAllMedia() {
        for (_, engine) in engines {
            engine.pauseAllMedia()
        }
    }

    func unmuteAllTabs() {
        for (_, engine) in engines {
            engine.setMuted(false)
        }
    }

    func installBoosts(_ entries: [BoostRuntimeEntry], forTabID id: Tab.ID, profileID: Profile.ID) {
        engines[TabEngineKey(tabID: id, profileID: profileID)]?.installBoosts(entries)
    }

    func refreshBoosts(forTabID id: Tab.ID, profileID: Profile.ID) {
        engines[TabEngineKey(tabID: id, profileID: profileID)]?.refreshBoostsOnPage()
    }

    func syncBoosts(for tab: Tab, profileID: Profile.ID, entries: [BoostRuntimeEntry]) {
        let engine = engine(for: tab, profileID: profileID)
        engine.installBoosts(entries)
        if let wk = engine as? WKEngine {
            wk.onBoostPageshow = { [weak self] in
                self?.refreshBoosts(forTabID: tab.id, profileID: profileID)
            }
        }
    }
}
