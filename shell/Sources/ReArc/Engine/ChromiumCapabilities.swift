import Foundation
import SidebarModel

/// Optional engine features the shell adopts. A feature is used only when the
/// engine reports ABI minor >= 5 and advertises its name, so an older engine
/// (the wave-11 ABI 1.0 build exports no minor version at all) keeps working
/// with the base feature set. Pure so the gating is testable without Chromium.
struct ChromiumCapabilities: Equatable {
    static let adoptedMinorVersion: UInt32 = 5
    static let navigationExtendedFeature = "navigation_extended"
    static let scriptEvaluationFeature = "script_evaluation"
    static let mediaMetadataSnapshotFeature = "media_metadata_snapshot"

    /// nil when the engine does not export `ReArcEngineABIMinorVersion`.
    var abiMinorVersion: UInt32?
    /// data:, file:, chrome://settings, chrome://version and view-source: navigation.
    var navigationExtended: Bool
    /// `ReArcTabEvaluateScript`.
    var scriptEvaluation: Bool
    /// Every media event carries an authoritative metadata snapshot.
    var mediaMetadataSnapshot: Bool

    static let none = ChromiumCapabilities(abiMinorVersion: nil, hasFeature: { _ in false })

    init(abiMinorVersion: UInt32?, hasFeature: (String) -> Bool) {
        self.abiMinorVersion = abiMinorVersion
        let adopted = (abiMinorVersion ?? 0) >= Self.adoptedMinorVersion
        navigationExtended = adopted && hasFeature(Self.navigationExtendedFeature)
        scriptEvaluation = adopted && hasFeature(Self.scriptEvaluationFeature)
        mediaMetadataSnapshot = adopted && hasFeature(Self.mediaMetadataSnapshotFeature)
    }

    var navigationSchemes: NavigationURLPolicy.EngineSchemes {
        navigationExtended ? .chromium : []
    }

    var summary: String {
        let minor = abiMinorVersion.map(String.init) ?? "absent"
        return "ABI minor \(minor): navigation_extended=\(navigationExtended ? 1 : 0) "
            + "script_evaluation=\(scriptEvaluation ? 1 : 0) "
            + "media_metadata_snapshot=\(mediaMetadataSnapshot ? 1 : 0)"
    }
}
