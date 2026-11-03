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
    }

    var navigationSchemes: NavigationURLPolicy.EngineSchemes {
        navigationExtended ? .chromium : []
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
        ]
        return "ABI minor \(minor): " + flags.map { "\($0.0)=\($0.1 ? 1 : 0)" }.joined(separator: " ")
    }
}
