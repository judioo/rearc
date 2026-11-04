#if REARC_CHROMIUM
import Foundation
import ReArcEngine
import SidebarModel

// Autofill suggestions (ABI 1.34), password leak detection (1.35), local
// card/address save offers (1.37) and HTTP authentication (1.38). Same rules
// as the 18c prompt channels: registered at `ready`, events copied, routed by
// tab to the engine; a request for a tab the shell does not know gets the
// conservative answer (dismiss, ignore, cancel).

private func string(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

/// Owned copy of `ReArcAutofillEvent`.
struct ChromiumAutofillEvent {
    enum Phase: UInt32 {
        case shown = 0, hidden, selection, openSettings
    }

    var profileID, tabID, contentGeneration, requestID: UInt64
    var phase: Phase
    var popup: AutofillPopup
    var settingsURL: String

    init?(_ pointer: UnsafePointer<ReArcAutofillEvent>?) {
        guard let e = pointer?.pointee, let phase = Phase(rawValue: e.phase) else { return nil }
        profileID = e.profile_id
        tabID = e.tab_id
        contentGeneration = e.content_generation
        requestID = e.request_id
        self.phase = phase
        var rows: [AutofillSuggestionRow] = []
        if let suggestions = e.suggestions {
            for index in 0..<e.suggestion_count {
                let s = suggestions[index]
                rows.append(AutofillSuggestionRow(
                    id: index, value: string(s.value), minor: string(s.minor), label: string(s.label), icon: string(s.icon),
                    kind: AutofillRowKind(rawValue: s.kind) ?? .other, isAcceptable: s.acceptable
                ))
            }
        }
        popup = AutofillPopup(
            requestID: e.request_id, tabID: e.tab_id, product: AutofillProduct(rawValue: e.product),
            field: CGRect(x: e.x, y: e.y, width: e.width, height: e.height), rows: rows,
            selected: e.selected >= 0 ? Int(e.selected) : nil
        )
        settingsURL = string(e.settings_url)
    }
}

struct ChromiumAutofillSaveEvent {
    var identity: ChromiumPromptIdentity
    var offer: AutofillSaveOffer
}

struct ChromiumHTTPAuthEvent {
    var identity: ChromiumPromptIdentity
    var challenge: HTTPAuthChallenge
}

private func autofillRuntime(_ context: UnsafeMutableRawPointer?) -> ChromiumRuntime {
    Unmanaged<ChromiumRuntime>.fromOpaque(context!).takeUnretainedValue()
}

private let autofillCallback: ReArcAutofillCallback = { context, event in
    guard let copied = ChromiumAutofillEvent(event) else { return }
    MainActor.assumeIsolated { autofillRuntime(context).handleAutofill(copied) }
}

private let autofillSaveCallback: ReArcAutofillSaveCallback = { context, event in
    guard let e = event?.pointee, let kind = AutofillSaveKind(rawValue: e.kind) else { return }
    let copied = ChromiumAutofillSaveEvent(
        identity: ChromiumPromptIdentity(profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation,
                                         requestID: e.request_id, isCancellation: e.phase == 1),
        offer: AutofillSaveOffer(id: e.request_id, kind: kind, isUpdate: e.update, origin: string(e.origin), summary: string(e.summary))
    )
    MainActor.assumeIsolated { autofillRuntime(context).handleAutofillSave(copied) }
}

private let httpAuthCallback: ReArcHttpAuthCallback = { context, event in
    guard let e = event?.pointee else { return }
    let copied = ChromiumHTTPAuthEvent(
        identity: ChromiumPromptIdentity(profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation,
                                         requestID: e.request_id, isCancellation: e.phase == 1),
        challenge: HTTPAuthChallenge(id: e.request_id, challenger: string(e.challenger), scheme: string(e.scheme),
                                     realm: string(e.realm), isProxy: e.is_proxy)
    )
    MainActor.assumeIsolated { autofillRuntime(context).handleHTTPAuth(copied) }
}

extension ChromiumRuntime {
    /// Registers the adopted channels; called at `ready`, before any tab exists.
    func registerAutofillChannels(context: UnsafeMutableRawPointer) {
        if capabilities.autofillSuggestions { ReArcEngineSetAutofillCallback(autofillCallback, context) }
        if capabilities.autofillSavePrompts { ReArcEngineSetAutofillSaveCallback(autofillSaveCallback, context) }
        if capabilities.httpAuth { ReArcEngineSetHttpAuthCallback(httpAuthCallback, context) }
    }

    // MARK: Events

    fileprivate func handleAutofill(_ event: ChromiumAutofillEvent) {
        ChromiumLog.trace("autofill_event phase \(event.phase) tab \(event.tabID) request \(event.requestID) product \(event.popup.product.rawValue) "
            + "field \(event.popup.field) rows \(event.popup.rows.count) selected \(event.popup.selected.map(String.init) ?? "-") "
            + "settings \(event.settingsURL.isEmpty ? "-" : event.settingsURL)")
        promptEvents["autofill", default: 0] += 1
        if event.phase == .openSettings {
            // "Manage…" (row or ReArcAutofillManage): Chromium's settings page, opened as a tab.
            if let url = URL(string: event.settingsURL) { onAutofillSettings?(url, engine(forTab: event.tabID)) }
            return
        }
        guard let engine = engine(forTab: event.tabID) else {
            if event.phase == .shown { dismissAutofill(event.requestID) }
            return
        }
        engine.handleAutofill(event)
    }

    fileprivate func handleAutofillSave(_ event: ChromiumAutofillSaveEvent) {
        let id = event.identity
        ChromiumLog.info("autofill_save_event tab \(id.tabID) request \(id.requestID) cancel \(id.isCancellation) kind \(event.offer.kind) "
            + "update \(event.offer.isUpdate) origin \(event.offer.origin)")
        promptEvents["autofill_save", default: 0] += 1
        guard let engine = engine(forTab: id.tabID) else {
            if !id.isCancellation { respondAutofillSave(id.requestID, .ignore) }
            return
        }
        engine.handleAutofillSave(event)
    }

    fileprivate func handleHTTPAuth(_ event: ChromiumHTTPAuthEvent) {
        let id = event.identity
        ChromiumLog.info("http_auth_event tab \(id.tabID) request \(id.requestID) cancel \(id.isCancellation) scheme \(event.challenge.scheme) "
            + "challenger \(event.challenge.challenger) proxy \(event.challenge.isProxy)")
        promptEvents["http_auth", default: 0] += 1
        guard let engine = engine(forTab: id.tabID) else {
            if !id.isCancellation { respondHTTPAuth(id.requestID, credentials: nil) }
            return
        }
        engine.handleHTTPAuth(event)
    }

    // MARK: Calls (main thread)

    @discardableResult
    func acceptAutofill(_ request: UInt64, index: Int) -> ReArcStatus {
        guard capabilities.autofillSuggestions, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcAutofillAccept(request, Int32(index))
        ChromiumLog.info("autofill accept \(request) row \(index) -> \(status.rearcName)")
        return status
    }

    @discardableResult
    func selectAutofill(_ request: UInt64, index: Int?) -> ReArcStatus {
        guard capabilities.autofillSuggestions, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        return ReArcAutofillSelect(request, Int32(index ?? -1))
    }

    @discardableResult
    func dismissAutofill(_ request: UInt64) -> ReArcStatus {
        guard capabilities.autofillSuggestions, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcAutofillDismiss(request)
        ChromiumLog.trace("autofill dismiss \(request) -> \(status.rearcName)")
        return status
    }

    @discardableResult
    func manageAutofill(_ request: UInt64) -> ReArcStatus {
        guard capabilities.autofillSuggestions, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcAutofillManage(request)
        ChromiumLog.info("autofill manage \(request) -> \(status.rearcName)")
        return status
    }

    @discardableResult
    func respondAutofillSave(_ request: UInt64, _ action: AutofillSaveAction) -> ReArcStatus {
        guard capabilities.autofillSavePrompts, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcAutofillSaveRespond(request, action.rawValue)
        ChromiumLog.info("autofill save reply \(request) \(action) -> \(status.rearcName)")
        promptReplies["autofill_save", default: 0] += 1
        return status
    }

    /// nil cancels. Credentials are copied by the engine and never logged.
    @discardableResult
    func respondHTTPAuth(_ request: UInt64, credentials: (username: String, password: String)?) -> ReArcStatus {
        guard capabilities.httpAuth, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status: ReArcStatus
        if let credentials {
            status = credentials.username.withCString { user in
                credentials.password.withCString { ReArcHttpAuthRespond(request, false, user, $0) }
            }
        } else {
            status = ReArcHttpAuthRespond(request, true, nil, nil)
        }
        ChromiumLog.info("http auth reply \(request) \(credentials == nil ? "cancel" : "credentials") -> \(status.rearcName)")
        promptReplies["http_auth", default: 0] += 1
        return status
    }

    // MARK: Password leak detection (ABI 1.35)

    /// (enabled, managed); nil when unsupported (off-the-record profiles, older engines).
    func passwordLeakDetection(profile: UInt64) -> (status: ReArcStatus, enabled: Bool, managed: Bool) {
        guard capabilities.passwordLeakDetection, isReady else { return (ReArcStatus(REARC_UNSUPPORTED), false, false) }
        var enabled = false, managed = false
        let status = ReArcProfileGetPasswordLeakDetection(profile, &enabled, &managed)
        return (status, enabled, managed)
    }

    @discardableResult
    func setPasswordLeakDetection(profile: UInt64, enabled: Bool) -> ReArcStatus {
        guard capabilities.passwordLeakDetection, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcProfileSetPasswordLeakDetection(profile, enabled)
        ChromiumLog.info("password leak detection profile \(profile) -> \(enabled ? "on" : "off"): \(status.rearcName)")
        return status
    }

    /// Persistent profiles open now (the default profile included).
    var openPersistentEngineProfiles: [UInt64] {
        var ids: [UInt64] = defaultProfileID == 0 ? [] : [defaultProfileID]
        for key in openProfileKeys where !key.isOffTheRecord {
            if let id = engineProfileID(for: key), !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// The menu's checkmark: the default profile's value (Chromium's default is on).
    var leakDetectionEnabled: Bool {
        let current = passwordLeakDetection(profile: defaultProfileID)
        return current.status == .rearcOK ? current.enabled : (leakDetectionPreference.explicitChoice ?? true)
    }

    /// ReArc > Check Passwords for Leaks: every open persistent profile now,
    /// later ones as they open. Profiles whose policy manages it keep the policy.
    func setLeakDetectionForAllProfiles(_ enabled: Bool, defaults: UserDefaults = .standard) {
        leakDetectionPreference.explicitChoice = enabled
        leakDetectionPreference.save(to: defaults)
        for profile in openPersistentEngineProfiles {
            let current = passwordLeakDetection(profile: profile)
            if current.status == .rearcOK, !current.managed, current.enabled != enabled {
                setPasswordLeakDetection(profile: profile, enabled: enabled)
            }
        }
    }

    /// Applies ReArc > Check Passwords for Leaks to one profile that just opened.
    func applyLeakDetectionPreference(profile: UInt64) {
        guard capabilities.passwordLeakDetection, profile != 0 else { return }
        let current = passwordLeakDetection(profile: profile)
        guard current.status == .rearcOK,
              let value = leakDetectionPreference.valueToApply(current: current.enabled, managed: current.managed) else { return }
        setPasswordLeakDetection(profile: profile, enabled: value)
    }
}
#endif
