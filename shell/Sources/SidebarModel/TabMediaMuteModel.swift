import Foundation

/// Tracks user-initiated tab mutes (separate from engine-reported audibility).
public struct TabMediaMuteModel: Equatable, Sendable {
    public var userMutedTabIDs: Set<Tab.ID>

    public init(userMutedTabIDs: Set<Tab.ID> = []) {
        self.userMutedTabIDs = userMutedTabIDs
    }

    public mutating func markUserMuted(_ tabID: Tab.ID) {
        userMutedTabIDs.insert(tabID)
    }

    public mutating func markUserUnmuted(_ tabID: Tab.ID) {
        userMutedTabIDs.remove(tabID)
    }

    public mutating func clearAllUserMutes() {
        userMutedTabIDs.removeAll()
    }

    /// The row's speaker: shown while the tab plays sound, and while the user
    /// has it muted (a muted speaker that unmutes on click).
    public func showsAudibleIndicator(for tabID: Tab.ID, media: WebMediaState) -> Bool {
        media.isAudible || userMutedTabIDs.contains(tabID)
    }

    public func isUserMuted(_ tabID: Tab.ID) -> Bool {
        userMutedTabIDs.contains(tabID)
    }

    public static func shouldEnableMuteTab(selectedTabID: Tab.ID?, media: WebMediaState?) -> Bool {
        guard selectedTabID != nil, let media else { return false }
        return media.isAudible
    }

    public static func shouldEnableUnmuteAll(
        mediaByTab: [Tab.ID: WebMediaState],
        muteModel: TabMediaMuteModel
    ) -> Bool {
        if !muteModel.userMutedTabIDs.isEmpty { return true }
        return mediaByTab.values.contains(where: { $0.isAudible })
    }

    public static func shouldEnablePauseAll(mediaByTab: [Tab.ID: WebMediaState]) -> Bool {
        mediaByTab.values.contains(where: \.isPlaying)
    }
}
