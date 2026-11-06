#if REARC_CHROMIUM
import Foundation
import Observation
import SidebarModel

/// Settings › Profiles' Search engine pop-up on Chromium: each profile's list
/// from `search_engines` (ABI 1.46), fetched the first time the pane reads it
/// and kept until the default changes.
@MainActor
@Observable
final class ChromiumSearchEngineSettings: SearchEngineSettings {
    @ObservationIgnored private let runtime: ChromiumRuntime
    private var choices: [Profile.ID: SearchEngineChoices] = [:]
    @ObservationIgnored private var loading: Set<Profile.ID> = []

    init(runtime: ChromiumRuntime) { self.runtime = runtime }

    func engines(for profileID: Profile.ID) -> [SearchEngineChoice] {
        guard let list = list(for: profileID) else { return [] }
        return list.engines.filter { $0.canMakeDefault || $0.isDefault }
            .map { SearchEngineChoice(id: String($0.id), name: $0.name) }
    }

    func defaultEngine(for profileID: Profile.ID) -> SearchEngineChoice.ID? {
        list(for: profileID)?.current.map { String($0.id) }
    }

    func isEditable(for profileID: Profile.ID) -> Bool {
        list(for: profileID)?.isEditable ?? false
    }

    func setDefaultEngine(_ id: SearchEngineChoice.ID, for profileID: Profile.ID) {
        guard let engineID = Int64(id) else { return }
        runtime.setDefaultSearchEngine(engineID, for: profileID) { [weak self] accepted in
            guard let self, accepted, let list = self.choices[profileID] else { return }
            self.choices[profileID] = list.selecting(engineID)
        }
    }

    /// The cached list; a miss starts one fetch.
    private func list(for profileID: Profile.ID) -> SearchEngineChoices? {
        if let list = choices[profileID] { return list }
        if loading.insert(profileID).inserted {
            runtime.searchEngines(for: profileID) { [weak self] list in
                guard let self else { return }
                self.loading.remove(profileID)
                if let list { self.choices[profileID] = list }
            }
        }
        return nil
    }
}
#endif
