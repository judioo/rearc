#if REARC_CHROMIUM
import Foundation
import ReArcEngine
import SidebarModel

// Command-bar data from the engine (C-ABI.md "Profile history query and
// deletion (1.23)" and the search_autocomplete section of the header, 1.26).
// Every call is gated on its minor and feature, takes a persistent profile
// (the engine rejects off-the-record IDs) and completes once on a deferred
// UI task; a synchronous rejection runs no callback, so its context is
// released here. Strings and rows are borrowed for the callback and copied.

private func string(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

/// Retained (+1) context of one accepted call, released by its single callback.
private final class CallBox<Value> {
    static var live: Int { CallBoxCount.live }
    let body: (ReArcStatus, Value) -> Void
    init(_ body: @escaping (ReArcStatus, Value) -> Void) {
        self.body = body
        CallBoxCount.live += 1
    }
    deinit { CallBoxCount.live -= 1 }
}

enum CallBoxCount {
    /// Command-bar call contexts not yet released (self-test drains it to zero).
    static var live = 0
}

private let historyCallback: ReArcHistoryCallback = { context, status, _, entries, count in
    guard let context else { return }
    var rows: [ChromiumHistoryRow] = []
    if let entries {
        for index in 0..<count {
            let e = entries[index]
            rows.append(ChromiumHistoryRow(title: string(e.title), url: string(e.url), visitTimeUS: e.visit_time_us, visitCount: e.visit_count))
        }
    }
    let box = Unmanaged<CallBox<[ChromiumHistoryRow]>>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated { box.body(status, rows) }
}

private let providerCallback: ReArcSearchProviderCallback = { context, status, _, provider in
    guard let context else { return }
    let copied = provider.flatMap { p -> SearchProvider? in
        let e = p.pointee
        return ChromiumSearchMapping.provider(name: string(e.name), keyword: string(e.keyword),
                                              searchURL: string(e.search_url), suggestURL: string(e.suggest_url))
    }
    let box = Unmanaged<CallBox<SearchProvider?>>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated { box.body(status, copied) }
}

private let classifyCallback: ReArcClassifyCallback = { context, status, _, result in
    guard let context else { return }
    let copied = result.flatMap { ChromiumSearchMapping.classification(kind: $0.pointee.kind, destination: string($0.pointee.destination_url)) }
    let box = Unmanaged<CallBox<InputClassification?>>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated { box.body(status, copied) }
}

/// One autocomplete query: zero or more partial results, then exactly one with
/// done=true (OK or cancelled), which releases the context.
private final class AutocompleteBox {
    let body: (ChromiumAutocompleteUpdate) -> Void
    init(_ body: @escaping (ChromiumAutocompleteUpdate) -> Void) {
        self.body = body
        CallBoxCount.live += 1
    }
    deinit { CallBoxCount.live -= 1 }
}

/// Owned copy of one `ReArcAutocompleteResult`.
struct ChromiumAutocompleteUpdate {
    var status: ReArcStatus
    var queryID: UInt64
    var done: Bool
    var matches: [ChromiumAutocompleteMatch]
}

private let autocompleteCallback: ReArcAutocompleteCallback = { context, result in
    guard let context, let r = result?.pointee else { return }
    var matches: [ChromiumAutocompleteMatch] = []
    if let array = r.matches {
        for index in 0..<r.count {
            let m = array[index]
            matches.append(ChromiumAutocompleteMatch(
                kind: m.kind, matchType: m.match_type, relevance: m.relevance,
                allowedToBeDefault: m.allowed_to_be_default, deletable: m.deletable,
                contents: string(m.contents), description: string(m.description),
                destinationURL: string(m.destination_url), fillIntoEdit: string(m.fill_into_edit)
            ))
        }
    }
    let update = ChromiumAutocompleteUpdate(status: r.status, queryID: r.query_id, done: r.done, matches: matches)
    let unmanaged = Unmanaged<AutocompleteBox>.fromOpaque(context)
    let box = update.done ? unmanaged.takeRetainedValue() : unmanaged.takeUnretainedValue()
    MainActor.assumeIsolated { box.body(update) }
}

extension ChromiumRuntime {
    private var serviceReady: Bool { isReady && !isStopping }

    private func start<Value>(
        _ name: String,
        _ body: @escaping (ReArcStatus, Value) -> Void,
        _ call: (UnsafeMutableRawPointer) -> ReArcStatus
    ) -> ReArcStatus {
        let context = Unmanaged.passRetained(CallBox(body)).toOpaque()
        let status = call(context)
        if status != .rearcOK {
            Unmanaged<CallBox<Value>>.fromOpaque(context).release()
            ChromiumLog.trace("\(name) rejected: \(status.rearcName)")
        }
        return status
    }

    /// `ReArcHistoryQuery`: empty text lists recent pages, newest first.
    @discardableResult
    func queryHistory(profile: UInt64, text: String, limit: UInt32,
                      completion: @escaping (ReArcStatus, [ChromiumHistoryRow]) -> Void) -> ReArcStatus {
        guard capabilities.historyQuery, serviceReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        return start("history query", completion) { context in
            text.withCString { ReArcHistoryQuery(profile, $0, limit, historyCallback, context) }
        }
    }

    @discardableResult
    func deleteHistoryURL(profile: UInt64, url: String, completion: @escaping (ReArcStatus) -> Void) -> ReArcStatus {
        guard capabilities.historyQuery, serviceReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        return callAsync({ status, _ in completion(status) }) { context, trampoline in
            url.withCString { ReArcHistoryDeleteURL(profile, $0, trampoline, context) }
        }
    }

    @discardableResult
    func defaultSearchProvider(profile: UInt64, completion: @escaping (ReArcStatus, SearchProvider?) -> Void) -> ReArcStatus {
        guard capabilities.searchAutocomplete, serviceReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        return start("default search provider", completion) { context in
            ReArcSearchGetDefaultProvider(profile, providerCallback, context)
        }
    }

    /// `ReArcSearchSetDefaultProvider` (persistent profiles; a policy-managed default is invalid_state).
    @discardableResult
    func setDefaultSearchProvider(profile: UInt64, _ provider: SearchProvider, completion: @escaping (ReArcStatus) -> Void) -> ReArcStatus {
        guard capabilities.searchAutocomplete, serviceReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        return provider.name.withCString { name in
            provider.keyword.withCString { keyword in
                provider.searchTemplate.withCString { search in
                    (provider.suggestTemplate ?? "").withCString { suggest in
                        var value = ReArcSearchProvider(name: name, keyword: keyword, search_url: search, suggest_url: suggest,
                                                        is_managed: false, is_prepopulated: false)
                        return callAsync({ status, _ in completion(status) }) { context, trampoline in
                            ReArcSearchSetDefaultProvider(profile, &value, trampoline, context)
                        }
                    }
                }
            }
        }
    }

    /// `ReArcSearchClassifyInput`: Chromium's URL-vs-search decision (synchronous providers, no network).
    @discardableResult
    func classifyInput(profile: UInt64, text: String, completion: @escaping (ReArcStatus, InputClassification?) -> Void) -> ReArcStatus {
        guard capabilities.searchAutocomplete, serviceReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        return start("classify input", completion) { context in
            text.withCString { ReArcSearchClassifyInput(profile, $0, classifyCallback, context) }
        }
    }

    /// `ReArcAutocompleteStart` with inline autocompletion off (option 1). A
    /// new start supersedes the profile's previous query, which then ends
    /// with one cancelled result. Returns the query ID, or nil when rejected.
    @discardableResult
    func startAutocomplete(profile: UInt64, text: String, update: @escaping (ChromiumAutocompleteUpdate) -> Void) -> UInt64? {
        guard capabilities.searchAutocomplete, serviceReady else { return nil }
        let context = Unmanaged.passRetained(AutocompleteBox(update)).toOpaque()
        var queryID: UInt64 = 0
        let status = text.withCString { ReArcAutocompleteStart(profile, $0, 1, autocompleteCallback, context, &queryID) }
        guard status == .rearcOK else {
            Unmanaged<AutocompleteBox>.fromOpaque(context).release()
            ChromiumLog.trace("autocomplete start rejected: \(status.rearcName)")
            return nil
        }
        return queryID
    }

    @discardableResult
    func stopAutocomplete(profile: UInt64) -> ReArcStatus {
        guard capabilities.searchAutocomplete, serviceReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        return ReArcAutocompleteStop(profile)
    }

    /// Command-bar call contexts still waiting for their callback.
    var liveCommandBarContexts: Int { CallBoxCount.live }
}

/// The command bar on Chromium: history from the profile's HistoryService
/// (`history_query`), the default search, Chromium's URL-vs-search
/// classification and autocomplete suggestions (`search_autocomplete`).
/// Without a feature, that part falls back to the WebKit services (the
/// shell's search preference and visit store).
final class ChromiumCommandBarServices: CommandBarServices {
    static let historyLimit: UInt32 = 50

    private unowned let runtime: ChromiumRuntime
    let fallback: WebKitCommandBarServices
    private var providers: [Profile.ID: SearchProvider] = [:]
    private var providerRequests: Set<Profile.ID> = []
    /// Profiles whose default search could not be read; asked again when the bar opens.
    private var providerUnavailable: Set<Profile.ID> = []
    /// Bumped by every query and cancel; older callbacks are dropped.
    private var token = 0
    /// Profile of the running autocomplete query, for Stop.
    private var autocompleteProfile: UInt64?
    private(set) var autocompleteQueryID: UInt64?
    /// Results delivered, by source (logs and the self-test).
    private(set) var deliveries: [String: Int] = [:]
    var onSearchProviderChange: (() -> Void)?

    init(runtime: ChromiumRuntime, fallback: WebKitCommandBarServices = WebKitCommandBarServices()) {
        self.runtime = runtime
        self.fallback = fallback
        fallback.onSearchProviderChange = { [weak self] in self?.onSearchProviderChange?() }
    }

    private var capabilities: ChromiumCapabilities { runtime.capabilities }

    func searchProvider(for profileID: Profile.ID) -> SearchProvider {
        guard capabilities.searchAutocomplete else { return fallback.searchProvider(for: profileID) }
        if let provider = providers[profileID] { return provider }
        if !providerUnavailable.contains(profileID) { refreshSearchProvider(for: profileID) }
        return fallback.searchProvider(for: profileID)
    }

    /// chrome://settings/search may have changed the default since the last read.
    func commandBarWillOpen(profileID: Profile.ID) {
        providerUnavailable.remove(profileID)
        refreshSearchProvider(for: profileID)
    }

    /// Re-reads the profile's default search (it changes in chrome://settings/search).
    func refreshSearchProvider(for profileID: Profile.ID, completion: (() -> Void)? = nil) {
        guard capabilities.searchAutocomplete, providerRequests.insert(profileID).inserted else { return }
        runtime.withEngineProfile(.persistent(profileID)) { [weak self] engineID in
            guard let self else { return }
            guard let engineID else {
                self.providerRequests.remove(profileID)
                self.providerUnavailable.insert(profileID)
                return
            }
            let status = self.runtime.defaultSearchProvider(profile: engineID) { [weak self] status, provider in
                guard let self else { return }
                self.providerRequests.remove(profileID)
                if let provider, self.providers[profileID] != provider {
                    self.providers[profileID] = provider
                    ChromiumLog.info("default search for profile \(profileID): \(provider.name) \(provider.searchTemplate)")
                    self.onSearchProviderChange?()
                } else if provider == nil {
                    self.providerUnavailable.insert(profileID)
                    ChromiumLog.info("default search for profile \(profileID) unavailable: \(status.rearcName)")
                }
                completion?()
            }
            if status != .rearcOK {
                self.providerRequests.remove(profileID)
                self.providerUnavailable.insert(profileID)
            }
        }
    }

    func query(_ text: String, profileID: Profile.ID, isPrivate: Bool, deliver: @escaping (CommandBarLiveResults) -> Void) {
        cancel()
        let token = self.token
        let accumulated = Accumulator(query: text)
        let send: (String) -> Void = { [weak self] source in
            guard let self, self.token == token else { return }
            self.deliveries[source, default: 0] += 1
            deliver(accumulated.results)
        }
        if !capabilities.searchAutocomplete {
            fallback.query(text, profileID: profileID, isPrivate: isPrivate) { results in
                accumulated.results.suggestions = results.suggestions
                send("suggest")
            }
        }
        // Off-the-record profiles have no reachable history and never ask the provider.
        guard !isPrivate, capabilities.historyQuery || capabilities.searchAutocomplete else { return }
        runtime.withEngineProfile(.persistent(profileID)) { [weak self] engineID in
            guard let self, self.token == token, let engineID else { return }
            if self.capabilities.historyQuery {
                self.runtime.queryHistory(profile: engineID, text: text, limit: Self.historyLimit) { status, rows in
                    guard status == .rearcOK else { return }
                    accumulated.results.history = rows.compactMap(\.record)
                    send("history")
                }
            }
            guard self.capabilities.searchAutocomplete else { return }
            self.runtime.classifyInput(profile: engineID, text: text) { status, classification in
                guard status == .rearcOK else { return }
                accumulated.results.classification = classification
                send("classify")
            }
            self.autocompleteProfile = engineID
            self.autocompleteQueryID = self.runtime.startAutocomplete(profile: engineID, text: text) { [weak self] update in
                ChromiumLog.trace("autocomplete query \(update.queryID) done \(update.done) \(update.status.rearcName): "
                    + update.matches.map { "\($0.kind)/\($0.matchType) '\($0.contents)'" }.joined(separator: ", "))
                guard let self, self.token == token, update.queryID == self.autocompleteQueryID else { return }
                if update.done {
                    self.autocompleteProfile = nil
                    self.autocompleteQueryID = nil
                }
                guard update.status == .rearcOK else { return }
                // Chromium can carry the previous query's cached suggestions
                // in a partial update. Keep history/classification responsive,
                // but publish suggestions only when this query has finished.
                guard update.done else { return }
                accumulated.results.suggestions = ChromiumSearchMapping.suggestions(update.matches)
                send("autocomplete")
            }
        }
    }

    func cancel() {
        token += 1
        fallback.cancel()
        if let profile = autocompleteProfile {
            runtime.stopAutocomplete(profile: profile)
            autocompleteProfile = nil
            autocompleteQueryID = nil
        }
    }

    func deleteFromHistory(_ url: URL, profileID: Profile.ID, completion: @escaping (Bool) -> Void) -> Bool {
        guard capabilities.historyQuery, let engineID = runtime.engineProfileID(for: .persistent(profileID)) else { return false }
        let status = runtime.deleteHistoryURL(profile: engineID, url: url.absoluteString) { status in
            ChromiumLog.info("history delete \(url.absoluteString): \(status.rearcName)")
            completion(status == .rearcOK)
        }
        return status == .rearcOK
    }

    private final class Accumulator {
        var results: CommandBarLiveResults
        init(query: String) { results = CommandBarLiveResults(query: query) }
    }
}
#endif
