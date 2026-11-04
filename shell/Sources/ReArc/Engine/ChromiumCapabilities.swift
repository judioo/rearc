import Foundation
import SidebarModel

/// Optional engine features the shell adopts. Each feature is used only when
/// the engine reports at least the ABI minor version that introduced it and
/// advertises its name, so an older engine (the wave-11 ABI 1.0 build exports
/// no minor version at all) keeps working with the base feature set. Pure so
/// the gating is testable without Chromium.
struct ChromiumCapabilities: Equatable {
    static let navigationExtendedFeature = "navigation_extended"
    static let scriptEvaluationFeature = "script_evaluation"
    static let mediaMetadataSnapshotFeature = "media_metadata_snapshot"
    static let profilesFeature = "profiles"
    static let profileOffTheRecordFeature = "profile_off_the_record"
    static let scriptEvaluationIdentityFeature = "script_evaluation_identity"
    static let pageZoomFeature = "page_zoom"
    static let isolatedPageMessagesFeature = "isolated_page_messages"
    static let safeStorageBrandingFeature = "rearc_safe_storage_branding"
    static let osPermissionShutdownFeature = "os_permission_shutdown"
    static let shutdownPendingClosesFeature = "shutdown_pending_closes"
    static let profileDirectoryFeature = "profile_directory"
    static let webUIDailyPagesFeature = "webui_daily_pages"
    static let historyRecordingFeature = "history_recording"
    static let passwordAutofillFeature = "password_autofill"
    static let findInPageFeature = "find_in_page"
    static let downloadsFeature = "downloads"
    static let javascriptDialogsFeature = "javascript_dialogs"
    static let fileChooserFeature = "file_chooser"
    static let permissionPromptsFeature = "permission_prompts"
    static let contextMenuFeature = "context_menu"
    static let passwordPromptsFeature = "password_prompts"
    /// Provisional: no engine advertises page inspection yet (ABI 1.21's
    /// Inspect command is `unsupported`). Inspect stays disabled until one does.
    static let devToolsFeature = "devtools"

    /// ABI minor version that introduced each adopted feature (C-ABI.md).
    static let introducedIn: [String: UInt32] = [
        navigationExtendedFeature: 5,
        scriptEvaluationFeature: 5,
        mediaMetadataSnapshotFeature: 5,
        profilesFeature: 6,
        profileOffTheRecordFeature: 6,
        scriptEvaluationIdentityFeature: 7,
        pageZoomFeature: 8,
        isolatedPageMessagesFeature: 9,
        safeStorageBrandingFeature: 10,
        osPermissionShutdownFeature: 11,
        shutdownPendingClosesFeature: 12,
        profileDirectoryFeature: 13,
        webUIDailyPagesFeature: 14,
        historyRecordingFeature: 15,
        passwordAutofillFeature: 15,
        findInPageFeature: 16,
        downloadsFeature: 17,
        javascriptDialogsFeature: 18,
        fileChooserFeature: 19,
        permissionPromptsFeature: 20,
        contextMenuFeature: 21,
        passwordPromptsFeature: 22,
        devToolsFeature: 25,
    ]

    /// nil when the engine does not export `ReArcEngineABIMinorVersion`.
    var abiMinorVersion: UInt32?
    /// data:, file:, chrome://settings, chrome://version and view-source: navigation.
    var navigationExtended: Bool
    /// `ReArcTabEvaluateScript`.
    var scriptEvaluation: Bool
    /// Every media event carries an authoritative metadata snapshot.
    var mediaMetadataSnapshot: Bool
    /// Named persistent profiles (`ReArcProfileOpen` / `ReArcProfileClose`).
    var profiles: Bool
    /// `ReArcProfileCreateOffTheRecord`; requires `profiles`.
    var profileOffTheRecord: Bool
    /// `ReArcTabEvaluateScript2` and `ReArcTabGetDocumentIdentity`; requires `scriptEvaluation`.
    var scriptEvaluationIdentity: Bool
    /// Chromium page zoom (get/set factor, zoom events).
    var pageZoom: Bool
    /// `rearcPostMessage` in isolated worlds, delivered to the page-message callback.
    var isolatedPageMessages: Bool
    /// Safe Storage keychain item named "ReArc Safe Storage" (build-time branding).
    var safeStorageBranding: Bool
    /// Shutdown no longer waits on read-only macOS permission (TCC) queries. No Swift call.
    var osPermissionShutdown: Bool
    /// `ReArcEngineShutdown` joins standalone tab closes still in flight.
    var shutdownPendingCloses: Bool
    /// `ReArcProfileOpenDirectory`: open an existing profile directory in place; requires `profiles`.
    var profileDirectory: Bool
    /// chrome://history, downloads, password-manager and extensions; requires `navigationExtended`.
    var webUIDailyPages: Bool
    /// Chromium's HistoryTabHelper records every non-OTR tab (chrome://history). No Swift call.
    var historyRecording: Bool
    /// ChromePasswordManagerClient fills saved credentials (save offers: `passwordPrompts`). No Swift call.
    var passwordAutofill: Bool
    /// `ReArcTabFindStart/Next/Stop` and find result events.
    var findInPage: Bool
    /// Download events, `ReArcDownloadSetPolicy` and `ReArcDownloadAction`.
    var downloads: Bool
    /// alert/confirm/prompt/beforeunload requests and `ReArcJavaScriptDialogRespond`.
    var javascriptDialogs: Bool
    /// `<input type=file>` and download save-path requests, `ReArcFileChooserRespond`.
    var fileChooser: Bool
    /// Permission requests and `ReArcPermissionRespond` (with persist).
    var permissionPrompts: Bool
    /// Page context menu events and `ReArcContextMenuCommand`.
    var contextMenu: Bool
    /// Password save/update offers and `ReArcPasswordPromptRespond`; requires `passwordAutofill`.
    var passwordPrompts: Bool
    /// Page inspection from the context menu (no engine has it yet).
    var devTools: Bool

    static let none = ChromiumCapabilities(abiMinorVersion: nil, hasFeature: { _ in false })

    init(abiMinorVersion: UInt32?, hasFeature: (String) -> Bool) {
        self.abiMinorVersion = abiMinorVersion
        let minor = abiMinorVersion ?? 0
        func adopted(_ feature: String) -> Bool {
            minor >= (Self.introducedIn[feature] ?? .max) && hasFeature(feature)
        }
        navigationExtended = adopted(Self.navigationExtendedFeature)
        scriptEvaluation = adopted(Self.scriptEvaluationFeature)
        mediaMetadataSnapshot = adopted(Self.mediaMetadataSnapshotFeature)
        profiles = adopted(Self.profilesFeature)
        profileOffTheRecord = profiles && adopted(Self.profileOffTheRecordFeature)
        scriptEvaluationIdentity = scriptEvaluation && adopted(Self.scriptEvaluationIdentityFeature)
        pageZoom = adopted(Self.pageZoomFeature)
        isolatedPageMessages = adopted(Self.isolatedPageMessagesFeature)
        safeStorageBranding = adopted(Self.safeStorageBrandingFeature)
        osPermissionShutdown = adopted(Self.osPermissionShutdownFeature)
        shutdownPendingCloses = adopted(Self.shutdownPendingClosesFeature)
        profileDirectory = profiles && adopted(Self.profileDirectoryFeature)
        webUIDailyPages = navigationExtended && adopted(Self.webUIDailyPagesFeature)
        historyRecording = adopted(Self.historyRecordingFeature)
        passwordAutofill = adopted(Self.passwordAutofillFeature)
        findInPage = adopted(Self.findInPageFeature)
        downloads = adopted(Self.downloadsFeature)
        javascriptDialogs = adopted(Self.javascriptDialogsFeature)
        fileChooser = adopted(Self.fileChooserFeature)
        permissionPrompts = adopted(Self.permissionPromptsFeature)
        contextMenu = adopted(Self.contextMenuFeature)
        passwordPrompts = passwordAutofill && adopted(Self.passwordPromptsFeature)
        devTools = contextMenu && adopted(Self.devToolsFeature)
    }

    /// "Ask where to save" for downloads: download policy prompt 1 needs a host file chooser (ABI 1.19).
    var downloadSavePrompt: Bool { downloads && fileChooser }

    /// WAVE-18-REPORT concern A gate: both browser-less helper features at 1.15.
    var browserlessHelpers: Bool { historyRecording && passwordAutofill }

    var navigationSchemes: NavigationURLPolicy.EngineSchemes {
        guard navigationExtended else { return [] }
        return webUIDailyPages ? NavigationURLPolicy.EngineSchemes.chromium.union(.dailyWebUI) : .chromium
    }

    /// Keychain item the engine reads its Safe Storage key from.
    var safeStorageKeychainItem: String {
        safeStorageBranding ? "ReArc Safe Storage" : "Chromium Safe Storage"
    }

    var summary: String {
        let minor = abiMinorVersion.map(String.init) ?? "absent"
        let flags: [(String, Bool)] = [
            (Self.navigationExtendedFeature, navigationExtended),
            (Self.scriptEvaluationFeature, scriptEvaluation),
            (Self.mediaMetadataSnapshotFeature, mediaMetadataSnapshot),
            (Self.profilesFeature, profiles),
            (Self.profileOffTheRecordFeature, profileOffTheRecord),
            (Self.scriptEvaluationIdentityFeature, scriptEvaluationIdentity),
            (Self.pageZoomFeature, pageZoom),
            (Self.isolatedPageMessagesFeature, isolatedPageMessages),
            (Self.safeStorageBrandingFeature, safeStorageBranding),
            (Self.osPermissionShutdownFeature, osPermissionShutdown),
            (Self.shutdownPendingClosesFeature, shutdownPendingCloses),
            (Self.profileDirectoryFeature, profileDirectory),
            (Self.webUIDailyPagesFeature, webUIDailyPages),
            (Self.historyRecordingFeature, historyRecording),
            (Self.passwordAutofillFeature, passwordAutofill),
            (Self.findInPageFeature, findInPage),
            (Self.downloadsFeature, downloads),
            (Self.javascriptDialogsFeature, javascriptDialogs),
            (Self.fileChooserFeature, fileChooser),
            (Self.permissionPromptsFeature, permissionPrompts),
            (Self.contextMenuFeature, contextMenu),
            (Self.passwordPromptsFeature, passwordPrompts),
            (Self.devToolsFeature, devTools),
        ]
        return "ABI minor \(minor): " + flags.map { "\($0.0)=\($0.1 ? 1 : 0)" }.joined(separator: " ")
    }
}
