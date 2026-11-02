import Foundation

/// When to show the sidebar mini player for background audio/video.
public enum MiniPlayerVisibility {

    /// Tab id to surface in the mini player, if any.
    public static func activeMiniPlayerTab(
        mediaByTab: [Tab.ID: WebMediaState],
        selectedTabID: Tab.ID?,
        activeSpaceID: Space.ID,
        spaceForTab: (Tab.ID) -> Space.ID?
    ) -> Tab.ID? {
        let audibleTabs = mediaByTab.filter { $0.value.isAudible || $0.value.isPlaying }.map(\.key)
        guard !audibleTabs.isEmpty else { return nil }

        let background = audibleTabs.filter { tabID in
            guard let selectedTabID else { return true }
            return tabID != selectedTabID
        }
        guard !background.isEmpty else { return nil }

        let otherSpace = background.filter { spaceForTab($0) != activeSpaceID }
        if let pick = otherSpace.first ?? background.first {
            return pick
        }
        return nil
    }
}
