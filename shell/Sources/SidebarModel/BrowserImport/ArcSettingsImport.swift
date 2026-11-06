import Foundation

/// The Arc settings ReArc has its own place for (PROFILE-IMPORT §4.2),
/// read from Arc's preferences domain. Each is nil when Arc has no value
/// ReArc understands; everything else in the domain is left alone.
public struct ArcSettingsImport: Equatable, Sendable {
    /// `shouldWarnBeforeQuitting` → Settings › General › Warn before quitting.
    public var warnBeforeQuitting: Bool?
    /// `arc_quitAlwaysKeepsWindows` → Settings › Advanced › restore windows.
    public var restoreWindows: Bool?
    /// `openExternalLinksInLittleBrowserEnabled` → Settings › Links.
    public var externalLinkDestination: ExternalLinkDestination?
    /// `autoArchiveTimeThreshold` → the active profile's Archive tabs after.
    /// Arc's values are ReArc's raw values.
    public var autoArchive: AutoArchiveThreshold?
    /// `autoArchiveLittleArcTimeThreshold` → Settings › Links › Archive Little Arcs after.
    public var littleArcArchive: AutoArchiveThreshold?

    public init() {}

    public var count: Int {
        [warnBeforeQuitting != nil, restoreWindows != nil, externalLinkDestination != nil,
         autoArchive != nil, littleArcArchive != nil].filter { $0 }.count
    }

    /// From `UserDefaults(suiteName: ImportBrowser.arc.defaultsDomain)?.dictionaryRepresentation()`.
    public static func read(_ values: [String: Any]) -> ArcSettingsImport {
        var settings = ArcSettingsImport()
        settings.warnBeforeQuitting = values["shouldWarnBeforeQuitting"] as? Bool
        settings.restoreWindows = values["arc_quitAlwaysKeepsWindows"] as? Bool
        settings.externalLinkDestination = (values["openExternalLinksInLittleBrowserEnabled"] as? Bool).map { $0 ? .littleArc : .activeSpace }
        settings.autoArchive = (values["autoArchiveTimeThreshold"] as? String).flatMap(AutoArchiveThreshold.init(rawValue:))
        settings.littleArcArchive = (values["autoArchiveLittleArcTimeThreshold"] as? String).flatMap(AutoArchiveThreshold.init(rawValue:))
        return settings
    }
}
