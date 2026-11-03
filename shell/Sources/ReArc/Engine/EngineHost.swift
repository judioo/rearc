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

    private var engines: [TabEngineKey: any WebEngine] = [:]
    private var ephemeralEngines: [EphemeralEngineKey: any WebEngine] = [:]
    private var littleArcEngines: [LittleArcEngineKey: any WebEngine] = [:]

    /// Favorites are global in the sidebar, but each favorite tab's engine uses
    /// the **active** profile's storage at load time (see `BrowserViewModel.profileID(for:)`).
    func engine(for tab: Tab, profileID: Profile.ID) -> any WebEngine {
        let key = TabEngineKey(tabID: tab.id, profileID: profileID)
        if let existing = engines[key] { return existing }
        let context = EngineProfileContext(profileID: profileID)
        let created = makeEngine(context: context, role: .tab, shellID: tab.id)
        engines[key] = created
        return created
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
        #if REARC_CHROMIUM
        if let runtime = ChromiumRuntime.active {
            return ChromiumEngine(runtime: runtime, context: context, role: role, shellID: shellID, privateSession: privateSession)
        }
        #endif
        return WKEngine(context: context)
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

    /// Binds an engine the shell did not create (a Chromium-created tab) to a sidebar tab.
    func adopt(_ engine: any WebEngine, for tab: Tab, profileID: Profile.ID) {
        engines[TabEngineKey(tabID: tab.id, profileID: profileID)] = engine
    }

    func engine(forTabID id: Tab.ID, profileID: Profile.ID) -> (any WebEngine)? {
        engines[TabEngineKey(tabID: id, profileID: profileID)]
    }

    func allTabEngines() -> [(Tab.ID, Profile.ID, any WebEngine)] {
        engines.map { (key, engine) in (key.tabID, key.profileID, engine) }
    }

    /// Drops cached engines for the given tab ids (all profile contexts).
    func evictEngines(forTabIDs ids: [Tab.ID]) {
        let idSet = Set(ids)
        engines = engines.filter { !idSet.contains($0.key.tabID) }
    }

    /// Drops every engine (tabs, peeks, Little Arc) that used the given profile.
    func evictEngines(forProfileID id: Profile.ID) {
        engines = engines.filter { $0.key.profileID != id }
        ephemeralEngines = ephemeralEngines.filter { $0.key.profileID != id }
        littleArcEngines = littleArcEngines.filter { $0.key.profileID != id }
    }

    /// Removes tab engines whose tab/profile pair is not in the live sidebar ownership set.
    func pruneTabEngines(retaining keys: Set<TabEngineKey>) {
        engines = engines.filter { keys.contains($0.key) }
    }

    func pruneLittleArcEngines(retaining keys: Set<LittleArcEngineKey>) {
        littleArcEngines = littleArcEngines.filter { keys.contains($0.key) }
    }

    func pruneEphemeralEngines(retaining keys: Set<EphemeralEngineKey>) {
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
        engines = engines.filter { $0.key.tabID != id }
    }

    func engine(forLittleArc id: UUID, profileID: Profile.ID) -> any WebEngine {
        let key = LittleArcEngineKey(id: id, profileID: profileID)
        if let existing = littleArcEngines[key] { return existing }
        let context = EngineProfileContext(profileID: profileID)
        let created = makeEngine(context: context, role: .littleArc, shellID: id)
        littleArcEngines[key] = created
        return created
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
