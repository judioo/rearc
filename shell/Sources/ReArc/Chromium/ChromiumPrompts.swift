#if REARC_CHROMIUM
import Foundation
import ReArcEngine
import SidebarModel

// Host prompt channels (ABI 1.18–1.22, C-ABI.md "Host prompt channels (wave
// 18c)"). Each channel is registered at `ready`, before any tab, only when
// the engine reports its minor and feature. Events are deferred Chromium UI
// tasks with borrowed strings: they are copied here, then routed by tab to
// the engine's `PagePromptCenter`. Phase 1 withdraws a request and needs no
// reply. A reply consumes the request; a late one is `not_found`. A request
// for a tab the shell does not know gets the conservative answer at once.

/// Request identity shared by every channel event.
struct ChromiumPromptIdentity: Equatable {
    var profileID, tabID, contentGeneration, requestID: UInt64
    /// 0 request, 1 cancellation.
    var isCancellation: Bool
}

private func strings(_ array: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int) -> [String] {
    guard let array, count > 0 else { return [] }
    return (0..<count).compactMap { array[$0].map { String(cString: $0) } }
}

private func string(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

struct ChromiumDialogEvent {
    var identity: ChromiumPromptIdentity
    var request: JavaScriptDialogRequest

    init?(_ pointer: UnsafePointer<ReArcJavaScriptDialogEvent>?) {
        guard let e = pointer?.pointee else { return nil }
        identity = ChromiumPromptIdentity(profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation,
                                          requestID: e.request_id, isCancellation: e.phase == 1)
        request = JavaScriptDialogRequest(
            id: e.request_id,
            kind: JavaScriptDialogKind(rawValue: e.kind) ?? .alert,
            message: string(e.message),
            defaultText: string(e.default_text),
            origin: string(e.origin),
            isReload: e.is_reload
        )
    }
}

struct ChromiumFileChooserEvent {
    var identity: ChromiumPromptIdentity
    var request: FileChooserRequest

    init?(_ pointer: UnsafePointer<ReArcFileChooserEvent>?) {
        guard let e = pointer?.pointee else { return nil }
        identity = ChromiumPromptIdentity(profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation,
                                          requestID: e.request_id, isCancellation: e.phase == 1)
        request = FileChooserRequest(
            id: e.request_id,
            mode: FileChooserMode(rawValue: e.mode) ?? .open,
            origin: string(e.origin),
            title: string(e.title),
            defaultPath: string(e.default_path),
            acceptTypes: strings(e.accept_types, e.accept_type_count)
        )
    }
}

struct ChromiumPermissionEvent {
    var identity: ChromiumPromptIdentity
    var request: PermissionPromptRequest

    init?(_ pointer: UnsafePointer<ReArcPermissionEvent>?) {
        guard let e = pointer?.pointee else { return nil }
        identity = ChromiumPromptIdentity(profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation,
                                          requestID: e.request_id, isCancellation: e.phase == 1)
        request = PermissionPromptRequest(
            id: e.request_id,
            origin: string(e.origin),
            embeddingOrigin: string(e.embedding_origin),
            types: strings(e.types, e.type_count).map(PermissionType.init)
        )
    }
}

struct ChromiumContextMenuEvent {
    var identity: ChromiumPromptIdentity
    var params: PageContextMenuParams
    /// RenderView-local DIP, top-left origin.
    var point: CGPoint

    init?(_ pointer: UnsafePointer<ReArcContextMenuEvent>?) {
        guard let e = pointer?.pointee else { return nil }
        identity = ChromiumPromptIdentity(profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation,
                                          requestID: e.request_id, isCancellation: e.phase == 1)
        params = PageContextMenuParams(
            linkURL: string(e.link_url),
            srcURL: string(e.src_url),
            selectionText: string(e.selection_text),
            pageURL: string(e.page_url),
            frameURL: string(e.frame_url),
            mediaType: PageContextMenuParams.MediaType(rawValue: e.media_type) ?? .none,
            editFlags: PageContextMenuParams.EditFlags(rawValue: e.edit_flags),
            isEditable: e.is_editable,
            hasImageContents: e.has_image_contents
        )
        point = CGPoint(x: CGFloat(e.x), y: CGFloat(e.y))
    }
}

struct ChromiumPasswordEvent {
    var identity: ChromiumPromptIdentity
    var prompt: PasswordSavePrompt

    init?(_ pointer: UnsafePointer<ReArcPasswordPromptEvent>?) {
        guard let e = pointer?.pointee else { return nil }
        identity = ChromiumPromptIdentity(profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation,
                                          requestID: e.request_id, isCancellation: e.phase == 1)
        prompt = PasswordSavePrompt(id: e.request_id, origin: string(e.origin), username: string(e.username), isUpdate: e.update)
    }
}

private func promptRuntime(_ context: UnsafeMutableRawPointer?) -> ChromiumRuntime {
    Unmanaged<ChromiumRuntime>.fromOpaque(context!).takeUnretainedValue()
}

private let dialogCallback: ReArcJavaScriptDialogCallback = { context, event in
    guard let copied = ChromiumDialogEvent(event) else { return }
    MainActor.assumeIsolated { promptRuntime(context).handleDialog(copied) }
}

private let fileChooserCallback: ReArcFileChooserCallback = { context, event in
    guard let copied = ChromiumFileChooserEvent(event) else { return }
    MainActor.assumeIsolated { promptRuntime(context).handleFileChooser(copied) }
}

private let permissionCallback: ReArcPermissionCallback = { context, event in
    guard let copied = ChromiumPermissionEvent(event) else { return }
    MainActor.assumeIsolated { promptRuntime(context).handlePermission(copied) }
}

private let contextMenuCallback: ReArcContextMenuCallback = { context, event in
    guard let copied = ChromiumContextMenuEvent(event) else { return }
    MainActor.assumeIsolated { promptRuntime(context).handleContextMenu(copied) }
}

private let passwordCallback: ReArcPasswordPromptCallback = { context, event in
    guard let copied = ChromiumPasswordEvent(event) else { return }
    MainActor.assumeIsolated { promptRuntime(context).handlePassword(copied) }
}

extension ChromiumRuntime {
    /// Registers each adopted channel; called at `ready`, before any tab exists.
    func registerPromptChannels(context: UnsafeMutableRawPointer) {
        if capabilities.javascriptDialogs { ReArcEngineSetJavaScriptDialogCallback(dialogCallback, context) }
        if capabilities.fileChooser { ReArcEngineSetFileChooserCallback(fileChooserCallback, context) }
        if capabilities.permissionPrompts { ReArcEngineSetPermissionCallback(permissionCallback, context) }
        if capabilities.contextMenu { ReArcEngineSetContextMenuCallback(contextMenuCallback, context) }
        if capabilities.passwordPrompts { ReArcEngineSetPasswordPromptCallback(passwordCallback, context) }
    }

    // MARK: Events

    fileprivate func handleDialog(_ event: ChromiumDialogEvent) {
        let id = event.identity
        ChromiumLog.trace("dialog_event tab \(id.tabID) request \(id.requestID) cancel \(id.isCancellation) kind \(event.request.kind) origin \(event.request.origin)")
        promptEvents["dialog", default: 0] += 1
        guard let engine = engine(forTab: id.tabID) else {
            if !id.isCancellation { respondDialog(id.requestID, JavaScriptDialogReply(accept: false)) }
            return
        }
        engine.handleDialog(event)
    }

    fileprivate func handleFileChooser(_ event: ChromiumFileChooserEvent) {
        let id = event.identity
        ChromiumLog.trace("file_chooser_event tab \(id.tabID) request \(id.requestID) cancel \(id.isCancellation) mode \(event.request.mode) accept \(event.request.acceptTypes)")
        promptEvents["file", default: 0] += 1
        if id.isCancellation { onDownloadSaveCancelled?(id.requestID) }
        if let engine = engine(forTab: id.tabID) {
            // Save requests come from "Ask where to save": a sheet on the downloading tab's window.
            return engine.handleFileChooser(event)
        }
        guard !id.isCancellation else { return }
        if event.request.isSave, let handler = onDownloadSaveRequest {
            handler(event)
        } else {
            respondFileChooser(id.requestID, paths: nil)
        }
    }

    fileprivate func handlePermission(_ event: ChromiumPermissionEvent) {
        let id = event.identity
        ChromiumLog.trace("permission_event tab \(id.tabID) request \(id.requestID) cancel \(id.isCancellation) types \(event.request.types.map(\.key)) origin \(event.request.origin)")
        promptEvents["permission", default: 0] += 1
        guard let engine = engine(forTab: id.tabID) else {
            if !id.isCancellation { respondPermission(id.requestID, .dismiss, persist: false) }
            return
        }
        engine.handlePermission(event)
    }

    fileprivate func handleContextMenu(_ event: ChromiumContextMenuEvent) {
        let id = event.identity
        ChromiumLog.trace("context_menu_event tab \(id.tabID) request \(id.requestID) cancel \(id.isCancellation) at \(event.point) link \(event.params.linkURL) media \(event.params.mediaType) editable \(event.params.isEditable) flags \(event.params.editFlags.rawValue)")
        promptEvents["context", default: 0] += 1
        guard let engine = engine(forTab: id.tabID) else {
            if !id.isCancellation { contextCommand(id.requestID, .dismiss) }
            return
        }
        engine.handleContextMenu(event)
    }

    fileprivate func handlePassword(_ event: ChromiumPasswordEvent) {
        let id = event.identity
        ChromiumLog.trace("password_event tab \(id.tabID) request \(id.requestID) cancel \(id.isCancellation) update \(event.prompt.isUpdate) origin \(event.prompt.origin)")
        promptEvents["password", default: 0] += 1
        guard let engine = engine(forTab: id.tabID) else {
            if !id.isCancellation { respondPassword(id.requestID, .notNow) }
            return
        }
        engine.handlePassword(event)
    }

    // MARK: Replies (main thread; each consumes its request)

    @discardableResult
    func respondDialog(_ request: UInt64, _ reply: JavaScriptDialogReply) -> ReArcStatus {
        guard capabilities.javascriptDialogs, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status: ReArcStatus
        if let text = reply.text {
            status = text.withCString { ReArcJavaScriptDialogRespond(request, reply.accept, $0) }
        } else {
            status = ReArcJavaScriptDialogRespond(request, reply.accept, nil)
        }
        logReply("dialog", request, "accept \(reply.accept)", status)
        return status
    }

    /// nil cancels; otherwise ABI-valid absolute paths.
    @discardableResult
    func respondFileChooser(_ request: UInt64, paths: [String]?) -> ReArcStatus {
        guard capabilities.fileChooser, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        guard let paths, !paths.isEmpty else {
            let status = ReArcFileChooserRespond(request, true, nil, 0)
            logReply("file", request, "cancel", status)
            return status
        }
        let owned = paths.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        let borrowed: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        let status = borrowed.withUnsafeBufferPointer { ReArcFileChooserRespond(request, false, $0.baseAddress, paths.count) }
        logReply("file", request, "\(paths.count) path(s)", status)
        return status
    }

    @discardableResult
    func respondPermission(_ request: UInt64, _ decision: PermissionDecision, persist: Bool) -> ReArcStatus {
        guard capabilities.permissionPrompts, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcPermissionRespond(request, decision.rawValue, decision != .dismiss && persist)
        logReply("permission", request, "\(decision) persist \(persist)", status)
        return status
    }

    @discardableResult
    func contextCommand(_ request: UInt64, _ command: ChromiumContextCommand) -> ReArcStatus {
        guard capabilities.contextMenu, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcContextMenuCommand(request, command.rawValue)
        logReply("context", request, "\(command)", status)
        return status
    }

    @discardableResult
    func respondPassword(_ request: UInt64, _ action: PasswordPromptAction) -> ReArcStatus {
        guard capabilities.passwordPrompts, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcPasswordPromptRespond(request, action.rawValue)
        logReply("password", request, "\(action)", status)
        return status
    }

    private func logReply(_ channel: String, _ request: UInt64, _ detail: String, _ status: ReArcStatus) {
        promptReplies[channel, default: 0] += 1
        if status == .rearcOK {
            ChromiumLog.trace("\(channel) reply \(request) \(detail) -> ok")
        } else {
            ChromiumLog.info("\(channel) reply \(request) \(detail) -> \(status.rearcName)")
        }
    }
}
#endif
