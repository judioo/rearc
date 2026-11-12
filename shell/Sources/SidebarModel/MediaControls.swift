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
        /// `userRequestedClose`: hidden until the tab starts playing again or
        /// moves to another item (Arc keys it on the media content: the next
        /// video of a playlist brings the strip back).
        public var isDismissed = false
    }

    /// Newest active first.
    public private(set) var entries: [Entry] = []
    private var playing: Set<UUID> = []
    private var titles: [UUID: String] = [:]

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
        for index in entries.indices where entries[index].isDismissed {
            let id = entries[index].tabID
            if let title = media[id]?.title, let before = titles[id], title != before { entries[index].isDismissed = false }
        }
        titles = media.compactMapValues(\.title)
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

    /// The sources whose video a Picture in Picture window really shows now,
    /// so their strips stay hidden (Arc swaps the two). The shell's floating
    /// panel counts only while it is on a screen with that tab's video
    /// (`panelTabID`); a `.panel` placement alone is not a player. An engine's
    /// own PiP window (WebKit's, Chromium's without `pip_embedded`) counts
    /// while the page is in PiP with no shell placement; with `pip_embedded`
    /// the engine opens none, so such a session has no player until the
    /// panel shows it. A sidebar card carries its strip row and a minimized
    /// panel is the strip, so neither hides one.
    public static func playersOnScreen(media: [UUID: WebMediaState], placements: [UUID: LiveVideoPlacement],
                                       panelTabID: UUID?, engineHasOwnPiPWindow: Bool) -> Set<UUID> {
        var shown: Set<UUID> = []
        if let panelTabID, placements[panelTabID]?.suppressesStrip == true { shown.insert(panelTabID) }
        guard engineHasOwnPiPWindow else { return shown }
        for (id, state) in media where state.isPictureInPicture && placements[id] == nil {
            shown.insert(id)
        }
        return shown
    }
}

/// Asks the sidebar list to scroll a row into view (a strip's go to tab).
/// `serial` makes a repeat a new request, though the selection did not move.
public struct SidebarReveal: Equatable, Sendable {
    public let id: UUID
    public let serial: Int

    public init(id: UUID, serial: Int) {
        self.id = id
        self.serial = serial
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

/// Whether a live video's view shows a picture: read back from its view a few
/// times while it plays (MINI-PLAYER.md §5.5). Nothing read back, or nothing
/// but black, is a blank player: the strip stays and the card shows a still.
/// A still non-black picture (a song's artwork) is a picture.
public enum LiveVideoDrawing {
    /// Each channel at most this: the overlay's own black, or a surface that never arrived.
    public static let blackLevel: UInt32 = 0x18

    public static func isBlank(_ samples: [UInt32?]) -> Bool {
        let read = samples.compactMap { $0 }
        return read.allSatisfy(isBlack)
    }

    /// 0xRRGGBBAA.
    public static func isBlack(_ rgba: UInt32) -> Bool {
        (rgba >> 24) & 0xFF <= blackLevel && (rgba >> 16) & 0xFF <= blackLevel && (rgba >> 8) & 0xFF <= blackLevel
    }
}
