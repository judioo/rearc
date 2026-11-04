import Foundation

/// Arc's sidebar media strips (MINI-PLAYER.md §3.2, `MediaControlsData`):
/// one entry per source tab with a media session. A tab gets an entry when it
/// starts playing; the entry stays while the session lives, paused included,
/// and a strip shows while its tab is not on screen. Ending the session,
/// closing the tab or the strip's close button removes it.
public struct MediaControlsModel: Equatable, Sendable {
    /// Arc's `maxActiveMediaControls` is unknown; ReArc stacks at most 3 [RA].
    public static let maxStrips = 3

    public struct Entry: Equatable, Sendable {
        public var tabID: UUID
        /// `userRequestedClose`: hidden until the tab starts playing again.
        public var isDismissed = false
    }

    /// Newest active first.
    public private(set) var entries: [Entry] = []
    private var playing: Set<UUID> = []

    public init() {}

    /// Follows the engines' media snapshots. A tab missing from `media` was
    /// closed or released, so its entry goes.
    public mutating func update(media: [UUID: WebMediaState]) {
        let startedNow = Set(media.filter { $0.value.isPlaying }.map(\.key))
        for id in startedNow.subtracting(playing).sorted(by: { $0.uuidString < $1.uuidString }) {
            entries.removeAll { $0.tabID == id }
            entries.insert(Entry(tabID: id), at: 0)
        }
        playing = startedNow
        entries.removeAll { media[$0.tabID]?.hasSession != true }
    }

    /// The strip's close button (Arc "Close Mini Player").
    public mutating func dismiss(_ tabID: UUID) {
        guard let index = entries.firstIndex(where: { $0.tabID == tabID }) else { return }
        entries[index].isDismissed = true
    }

    /// The strips to show in a window, front first: entries whose tab is not
    /// on screen there, minus `suppressed` (a source whose video shows in a
    /// floating PiP panel has no strip until the panel is minimized).
    public func strips(visibleTabIDs: Set<UUID>, suppressed: Set<UUID> = []) -> [UUID] {
        Array(entries.lazy
            .filter { !$0.isDismissed && !visibleTabIDs.contains($0.tabID) && !suppressed.contains($0.tabID) }
            .map(\.tabID)
            .prefix(Self.maxStrips))
    }

    public func contains(_ tabID: UUID) -> Bool {
        entries.contains { $0.tabID == tabID }
    }
}

/// Where a tab's live video (Chromium `pip_embedded`) is shown.
public enum LiveVideoPlacement: String, Equatable, Codable, Sendable {
    /// In the sidebar above the strip, at the sidebar's width [RA].
    case sidebar
    /// A floating Picture in Picture panel (Arc's PiP window).
    case panel
    /// The panel minimized into the strip; "Open Picture in Picture" brings it back.
    case minimized

    /// The placement a new live video starts in.
    public static func initial(embedsInSidebar: Bool, requestedPanel: Bool) -> LiveVideoPlacement {
        embedsInSidebar && !requestedPanel ? .sidebar : .panel
    }

    /// Where the video actually goes: a sidebar video needs a sidebar on screen.
    public func effective(sidebarVisible: Bool) -> LiveVideoPlacement {
        self == .sidebar && !sidebarVisible ? .panel : self
    }

    /// The strip hides while the panel shows the video (Arc swaps them).
    public var suppressesStrip: Bool { self == .panel }
    /// "Open Picture in Picture" in the strip (Arc `isBackToPIPButtonEnabled`).
    public var offersBackToPiP: Bool { self == .minimized }
}

/// The live video card's size (MINI-PLAYER.md §5.2): the sidebar's width
/// less the 8 pt insets, its height from the video's aspect ratio (16:9 when
/// unknown), clamped to 90…160 pt.
public enum LiveVideoLayout {
    public static let inset: Double = 8
    public static let stripHeight: Double = 33

    public static func videoHeight(sidebarWidth: Double, naturalSize: (width: Double, height: Double)?) -> Double {
        let width = max(0, sidebarWidth - 2 * inset)
        var aspect = 16.0 / 9.0
        if let size = naturalSize, size.width > 0, size.height > 0 { aspect = size.width / size.height }
        return min(160, max(90, (width / aspect).rounded()))
    }
}
