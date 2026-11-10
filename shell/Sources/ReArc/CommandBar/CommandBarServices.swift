import Foundation
import SidebarModel

/// The engine's side of the command bar: its default search, live history
/// and suggestions for the typed text, and history deletion. WebKit uses
/// the shell's search preference, its own visit store and the provider's
/// suggest endpoint (`WebKitCommandBarServices`); Chromium uses the
/// profile's HistoryService, TemplateURLService and AutocompleteController
/// (`ChromiumCommandBarServices`, ABI 1.23 and 1.26).
protocol CommandBarServices: AnyObject {
    /// The default search for a profile's command bar.
    func searchProvider(for profileID: Profile.ID) -> SearchProvider
    /// The command bar is opening: re-read anything that may have changed elsewhere.
    func commandBarWillOpen(profileID: Profile.ID)
    /// Starts the live lookups for `text`, superseding the previous query.
    /// `deliver` runs on the main thread, possibly several times as sources
    /// answer; each call carries everything known so far for `text`.
    func query(_ text: String, profileID: Profile.ID, isPrivate: Bool, deliver: @escaping (CommandBarLiveResults) -> Void)
    /// The command bar closed or left web input: stop outstanding lookups.
    func cancel()
    /// Deletes `url` from the engine's history. False when the engine keeps
    /// none the shell can reach (the shell's visit store is the history then).
    func deleteFromHistory(_ url: URL, profileID: Profile.ID, completion: @escaping (Bool) -> Void) -> Bool
    /// Runs when a profile's default search changes (menus and rows re-read it).
    var onSearchProviderChange: (() -> Void)? { get set }
}

/// One in-flight suggest request.
protocol SuggestFetch: AnyObject {
    func cancel()
}

/// Fetches a provider's OpenSearch suggestions (injected in tests).
protocol SuggestFetching {
    func fetch(_ url: URL, completion: @escaping (Data?) -> Void) -> SuggestFetch
}

extension URLSessionDataTask: SuggestFetch {}

/// Suggestions carry what the user is typing: a redirect off https is refused.
final class SuggestHTTPSRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

private final class RejectedSuggestFetch: SuggestFetch {
    func cancel() {}
}

/// Ephemeral session: no cookies, cache or credentials reach the provider.
/// Only https URLs are fetched.
struct URLSessionSuggestFetcher: SuggestFetching {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 4
        return URLSession(configuration: configuration, delegate: SuggestHTTPSRedirects(), delegateQueue: nil)
    }()

    func fetch(_ url: URL, completion: @escaping (Data?) -> Void) -> SuggestFetch {
        guard url.scheme?.lowercased() == "https" else {
            DispatchQueue.main.async { completion(nil) }
            return RejectedSuggestFetch()
        }
        var request = URLRequest(url: url)
        request.setValue("application/x-suggestions+json, application/json", forHTTPHeaderField: "Accept")
        let task = Self.session.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            DispatchQueue.main.async { completion(ok ? data : nil) }
        }
        task.resume()
        return task
    }
}

/// WebKit (and Chromium without `search_autocomplete`): the search
/// preference in user defaults, and suggestions from the provider's suggest
/// endpoint, debounced and cancelled on every keystroke. Private windows
/// never send the typed text anywhere.
final class WebKitCommandBarServices: CommandBarServices {
    private let defaults: UserDefaults
    private let fetcher: SuggestFetching
    private let debounce: TimeInterval
    private var pendingWork: DispatchWorkItem?
    private var inFlight: SuggestFetch?
    /// Bumped by every query and cancel: a cancelled request's late answer is dropped.
    private var token = 0
    /// Suggest requests started (tests and logs).
    private(set) var requestCount = 0
    var onSearchProviderChange: (() -> Void)?

    var preference: SearchProviderPreference {
        didSet {
            guard preference != oldValue else { return }
            preference.save(to: defaults)
            onSearchProviderChange?()
        }
    }

    init(defaults: UserDefaults = .standard, fetcher: SuggestFetching = URLSessionSuggestFetcher(), debounce: TimeInterval = 0.12) {
        self.defaults = defaults
        self.fetcher = fetcher
        self.debounce = debounce
        preference = SearchProviderPreference.load(from: defaults)
    }

    func searchProvider(for profileID: Profile.ID) -> SearchProvider {
        preference.provider
    }

    func commandBarWillOpen(profileID: Profile.ID) {}

    func query(_ text: String, profileID: Profile.ID, isPrivate: Bool, deliver: @escaping (CommandBarLiveResults) -> Void) {
        cancel()
        let provider = preference.provider
        guard preference.suggestionsEnabled, !isPrivate, let url = provider.suggestURL(for: text) else { return }
        let token = self.token
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.token == token else { return }
            self.pendingWork = nil
            self.requestCount += 1
            self.inFlight = self.fetcher.fetch(url) { [weak self] data in
                guard let self, self.token == token else { return }
                self.inFlight = nil
                let suggestions = data.map { SearchSuggestionParser.parse($0) } ?? []
                deliver(CommandBarLiveResults(
                    query: text,
                    suggestions: suggestions.compactMap { phrase in
                        provider.searchURL(for: phrase).map { SearchSuggestion(text: phrase, destinationURL: $0) }
                    }
                ))
            }
        }
        pendingWork = work
        if debounce > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
        } else {
            work.perform()
        }
    }

    func cancel() {
        token += 1
        pendingWork?.cancel()
        pendingWork = nil
        inFlight?.cancel()
        inFlight = nil
    }

    func deleteFromHistory(_ url: URL, profileID: Profile.ID, completion: @escaping (Bool) -> Void) -> Bool {
        false
    }
}
