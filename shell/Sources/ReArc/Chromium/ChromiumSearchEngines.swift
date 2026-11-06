#if REARC_CHROMIUM
import Foundation
import ReArcEngine
import SidebarModel

// The default search engine choice of a profile (ABI 1.46 `search_engines`,
// C-ABI.md "Media capture and search engines (1.46)"), for the Settings
// window's pop-up. Calls wait for the profile's TemplateURLService to load
// and complete once on a deferred UI task; a synchronous rejection runs no
// callback, so its context is released here. Off-the-record profiles list
// their original's engines and cannot change them.

private final class EngineListBox {
    let body: (ReArcStatus, SearchEngineChoices?) -> Void
    init(_ body: @escaping (ReArcStatus, SearchEngineChoices?) -> Void) { self.body = body }
}

private func engineString(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

private let engineListCallback: ReArcSearchEngineListCallback = { context, status, _, list in
    guard let context else { return }
    let copied = list.map { l -> SearchEngineChoices in
        let rows = UnsafeBufferPointer(start: l.pointee.engines, count: l.pointee.engines == nil ? 0 : l.pointee.count)
        return SearchEngineChoices(engines: rows.map { e in
            let favicon = engineString(e.favicon_url)
            return SearchEngineChoices.Engine(
                id: e.id, name: engineString(e.name), keyword: engineString(e.keyword),
                searchTemplate: engineString(e.search_url), faviconURL: favicon.isEmpty ? nil : URL(string: favicon),
                isDefault: e.is_default, isPrepopulated: e.is_prepopulated, canMakeDefault: e.can_make_default)
        }, isManaged: l.pointee.default_is_managed)
    }
    let box = Unmanaged<EngineListBox>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated { box.body(status, copied) }
}

extension ChromiumRuntime {
    /// `ReArcSearchListEngines` for an engine profile ID.
    @discardableResult
    func searchEngines(profile: UInt64, completion: @escaping (ReArcStatus, SearchEngineChoices?) -> Void) -> ReArcStatus {
        guard capabilities.searchEngines, isReady, !isStopping else { return ReArcStatus(REARC_UNSUPPORTED) }
        let context = Unmanaged.passRetained(EngineListBox(completion)).toOpaque()
        let status = ReArcSearchListEngines(profile, engineListCallback, context)
        if status != .rearcOK {
            Unmanaged<EngineListBox>.fromOpaque(context).release()
            ChromiumLog.info("search engine list rejected: \(status.rearcName)")
        }
        return status
    }

    /// `ReArcSearchSetDefaultEngine`: Chromium persists the user-selected default.
    /// A policy-managed default is invalid_state; an unknown ID not_found.
    @discardableResult
    func setDefaultSearchEngine(profile: UInt64, id: Int64, completion: @escaping (ReArcStatus) -> Void) -> ReArcStatus {
        guard capabilities.searchEngines, isReady, !isStopping else { return ReArcStatus(REARC_UNSUPPORTED) }
        return callAsync({ status, _ in completion(status) }) { context, trampoline in
            ReArcSearchSetDefaultEngine(profile, id, trampoline, context)
        }
    }

    /// The shell profile's choices; nil when the engine lacks the feature, the
    /// profile cannot be opened or the call fails.
    func searchEngines(for profileID: Profile.ID, completion: @escaping (SearchEngineChoices?) -> Void) {
        guard capabilities.searchEngines else { return completion(nil) }
        withEngineProfile(.persistent(profileID)) { [weak self] engineID in
            guard let self, let engineID else { return completion(nil) }
            let status = self.searchEngines(profile: engineID) { status, choices in
                completion(status == .rearcOK ? choices : nil)
            }
            if status != .rearcOK { completion(nil) }
        }
    }

    /// Makes `id` the shell profile's default search. The command bar re-reads
    /// its provider when it opens (`commandBarWillOpen`).
    func setDefaultSearchEngine(_ id: Int64, for profileID: Profile.ID, completion: @escaping (Bool) -> Void) {
        guard capabilities.searchEngines else { return completion(false) }
        withEngineProfile(.persistent(profileID)) { [weak self] engineID in
            guard let self, let engineID else { return completion(false) }
            let status = self.setDefaultSearchEngine(profile: engineID, id: id) { status in
                ChromiumLog.info("default search engine \(id) for profile \(profileID): \(status.rearcName)")
                completion(status == .rearcOK)
            }
            if status != .rearcOK { completion(false) }
        }
    }
}
#endif
