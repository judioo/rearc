import Foundation
import ReArcEngine

// Concern A: no new calls. Gate history/password UI claims on the features.
func browserlessHelpersAvailable() -> Bool {
    ReArcEngineABIMinorVersion() >= 15
        && ReArcEngineHasFeature("history_recording")
        && ReArcEngineHasFeature("password_autofill")
}

// Concern B: find in page.
final class FindController {
    private(set) var session: UInt64 = 0
    var onResult: ((Int32, Int32, Bool) -> Void)?
    var onEnded: ((UInt32) -> Void)?

    static var available: Bool {
        ReArcEngineABIMinorVersion() >= 16 && ReArcEngineHasFeature("find_in_page")
    }
    func install() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        ReArcEngineSetFindCallback({ context, event in
            guard let context, let event = event?.pointee else { return }
            let controller = Unmanaged<FindController>.fromOpaque(context).takeUnretainedValue()
            guard event.session_id == controller.session else { return }  // stale
            if event.reason != 0 {
                controller.session = 0
                controller.onEnded?(event.reason)
            } else if event.final_update {
                controller.onResult?(event.match_count, event.active_ordinal, true)
            }
        }, context)
    }
    func start(_ tab: UInt64, _ text: String, forward: Bool, matchCase: Bool) -> ReArcStatus {
        var options: UInt32 = 0
        if forward { options |= UInt32(REARC_FIND_FORWARD) }
        if matchCase { options |= UInt32(REARC_FIND_MATCH_CASE) }
        var id: UInt64 = 0
        let status = text.withCString { ReArcTabFindStart(tab, $0, options, &id) }
        if status == ReArcStatus(REARC_OK) { session = id }
        return status
    }
    func next(_ tab: UInt64, forward: Bool) -> ReArcStatus { ReArcTabFindNext(tab, forward) }
    func stop(_ tab: UInt64) -> ReArcStatus { ReArcTabFindStop(tab, 1) }
}

// Concern C: downloads.
struct DownloadRecord {
    var profile: UInt64, id: UInt32, tab: UInt64
    var url: String, path: String, mime: String
    var received: Int64, total: Int64
    var state: UInt32, danger: UInt32, reason: UInt32
    var paused: Bool, canResume: Bool
}
final class DownloadsController {
    var records: [String: DownloadRecord] = [:]  // keyed by guid
    static var available: Bool {
        ReArcEngineABIMinorVersion() >= 17 && ReArcEngineHasFeature("downloads")
    }
    func install(profile: UInt64, directory: URL) -> ReArcStatus {
        let context = Unmanaged.passUnretained(self).toOpaque()
        ReArcEngineSetDownloadCallback({ context, event in
            guard let context, let e = event?.pointee else { return }
            let controller = Unmanaged<DownloadsController>.fromOpaque(context).takeUnretainedValue()
            let guid = String(cString: e.guid)  // copy before returning
            if e.kind == 5 { controller.records[guid] = nil; return }
            controller.records[guid] = DownloadRecord(
                profile: e.profile_id, id: e.download_id, tab: e.tab_id,
                url: String(cString: e.url), path: String(cString: e.target_path),
                mime: String(cString: e.mime_type), received: e.received_bytes,
                total: e.total_bytes, state: e.state, danger: e.danger_type,
                reason: e.interrupt_reason, paused: e.paused, canResume: e.can_resume)
        }, context)
        return directory.path.withCString { ReArcDownloadSetPolicy(profile, $0, 0) }
    }
    // 0 pause, 1 resume, 2 cancel, 3 open, 4 reveal, 5 remove.
    func perform(_ record: DownloadRecord, _ action: UInt32) -> ReArcStatus {
        ReArcDownloadAction(record.profile, record.id, action)
    }
}
