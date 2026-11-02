import Foundation

/// Chooses which tab receives hardware media keys / Now Playing updates.
public enum MediaSessionRouting {

    public static func primaryMediaTab(
        mediaByTab: [Tab.ID: WebMediaState],
        selectedTabID: Tab.ID?
    ) -> Tab.ID? {
        if let selectedTabID,
           let state = mediaByTab[selectedTabID],
           state.isPlaying || state.isAudible {
            return selectedTabID
        }
        return mediaByTab
            .filter { $0.value.isAudible || $0.value.isPlaying }
            .map(\.key)
            .first
    }
}
