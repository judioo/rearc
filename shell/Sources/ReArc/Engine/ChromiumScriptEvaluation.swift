import Foundation

/// Raw `ReArcStatus` values needed by Chromium-free shell code. The header
/// enum is authoritative; it is importable only in REARC_CHROMIUM builds.
enum ChromiumStatusCode {
    static let ok: Int32 = 0
    static let invalidState: Int32 = 7
    static let unsupported: Int32 = 10
    static let busy: Int32 = 11
    static let cancelled: Int32 = 15
    static let scriptError: Int32 = 17
    static let timeout: Int32 = 18
}

/// Target world of `ReArcTabEvaluateScript` (C-ABI.md "Script evaluation").
enum ChromiumScriptWorld: Equatable {
    /// Isolated `rearc.boost.editor`, shared by the boost editor and picker.
    case editor
    /// Isolated world of an installed boost, to inspect its globals.
    case boost(UUID)
    /// The page's main world; only for intentional page interaction.
    case page

    /// world argument: 0 isolated, 1 main.
    var abiWorld: UInt32 {
        self == .page ? 1 : 0
    }

    /// boost_id argument: null selects the editor world (and is required for the main world).
    var boostID: String? {
        guard case .boost(let packageID) = self else { return nil }
        return packageID.uuidString.lowercased()
    }
}

/// The `{code,message,details}` error object of a failed evaluation.
struct ChromiumScriptErrorInfo: Equatable {
    var code: String
    var message: String
    /// `details` re-serialized as JSON (exception line/column etc.), if present.
    var detailsJSON: String?
}

enum ChromiumScriptError: Error, Equatable, CustomStringConvertible {
    /// The engine does not advertise script_evaluation (ABI < 1.5).
    case unsupported
    case noTab
    /// Synchronous rejection; no completion will follow.
    case rejected(Int32)
    /// The expression threw or its Promise rejected (script_error).
    case script(ChromiumScriptErrorInfo)
    /// The deadline passed; page side effects may still run (timeout).
    case timeout
    /// Navigation, close or target loss ended the document (cancelled).
    case cancelled
    /// Completed for a document the shell no longer shows (generation or navigation changed).
    case staleDocument
    /// Any other asynchronous status.
    case failed(Int32, ChromiumScriptErrorInfo?)
    case invalidResult(String)

    var description: String {
        switch self {
        case .unsupported: return "script evaluation unsupported by this engine"
        case .noTab: return "no Chromium tab"
        case .rejected(let status): return "evaluation rejected (status \(status))"
        case .script(let info): return "script_error \(info.code): \(info.message)"
        case .timeout: return "timeout"
        case .cancelled: return "cancelled (document went away)"
        case .staleDocument: return "stale document"
        case .failed(let status, let info): return "evaluation failed (status \(status)) \(info?.message ?? "")"
        case .invalidResult(let reason): return "invalid result: \(reason)"
        }
    }
}

/// Converts one copied evaluation completion into a decoded JSON value.
enum ChromiumScriptOutcome {
    static let defaultTimeoutMS: UInt32 = 3000
    static let timeoutRangeMS: ClosedRange<UInt32> = 1...30000

    /// Success JSON decodes as a fragment: a JS string arrives quoted, undefined as null (NSNull).
    static func decode(status: Int32, json: String?, errorJSON: String?) -> Result<Any, ChromiumScriptError> {
        switch status {
        case ChromiumStatusCode.ok:
            guard let json else { return .failure(.invalidResult("success without JSON")) }
            do {
                return .success(try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed))
            } catch {
                return .failure(.invalidResult("undecodable JSON"))
            }
        case ChromiumStatusCode.cancelled:
            return .failure(.cancelled)
        case ChromiumStatusCode.timeout:
            return .failure(.timeout)
        case ChromiumStatusCode.scriptError:
            return .failure(.script(errorInfo(errorJSON) ?? ChromiumScriptErrorInfo(code: "script_error", message: "", detailsJSON: nil)))
        default:
            return .failure(.failed(status, errorInfo(errorJSON)))
        }
    }

    static func errorInfo(_ errorJSON: String?) -> ChromiumScriptErrorInfo? {
        guard let errorJSON else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(errorJSON.utf8)) as? [String: Any] else {
            return ChromiumScriptErrorInfo(code: "unknown", message: errorJSON, detailsJSON: nil)
        }
        var details: String?
        if let value = object["details"], !(value is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) {
            details = String(decoding: data, as: UTF8.self)
        }
        return ChromiumScriptErrorInfo(
            code: object["code"] as? String ?? "unknown",
            message: object["message"] as? String ?? "",
            detailsJSON: details
        )
    }
}
