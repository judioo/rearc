import AppKit
import SidebarModel

/// Arc's sidebar media strips and ReArc's live video (wave 32,
/// MINI-PLAYER.md §3 and §5): which strips a window shows, where a tab's
/// live PiP video goes (sidebar card, floating panel or minimized into its
/// strip), and the strip and player buttons.
extension BrowserViewModel {
    /// A new key: the old one stored "on" from when that was the default.
    static let embedsVideoInSidebarKey = "ReArcSidebarVideo"

    // MARK: - What shows

    /// The tabs a window has on screen: its focused space's selected tab, or every pane of its split.
    func visibleTabIDs(in window: SidebarWindowID?) -> Set<Tab.ID> {
        guard let id = selectedItemID(in: window) else { return [] }
        if let split = store.split(withID: id) { return Set(split.tabs.map(\.id)) }
        return [id]
    }

    /// The strips for a window, front first: every source that is off screen
    /// here has one, whatever space, folder or profile it is in, and also
    /// while a Picture in Picture window shows it (Arc swaps the two). A
    /// floating window can be black (the shell's panel, build 677) or on
    /// another display, and a strip beside a working window costs little,
    /// where no strip beside a lost one loses the tab.
    func mediaStrips(in window: SidebarWindowID?) -> [Tab.ID] {
        var suppressed = MediaControlsModel.playersOnScreen(
            media: mediaStateByTab,
            placements: livePlacements.compactMapValues { $0.effective(sidebarVisible: showsLiveCardInSidebar) },
            panelTabID: nil,
            engineHasOwnPiPWindow: false
        )
        // A tab in a call shows its call card instead of a strip, as in Arc.
        suppressed.formUnion(captureStateByTab.keys)
        return mediaControls.strips(visibleTabIDs: visibleTabIDs(in: window), suppressed: suppressed)
    }

    /// Tabs using the camera or microphone that this window isn't showing:
    /// each gets a call card above the strips (Arc's Meet card).
    func callCards(in window: SidebarWindowID?) -> [Tab.ID] {
        let visible = visibleTabIDs(in: window)
        return captureStateByTab.keys
            .filter { !visible.contains($0) && store.tab(withID: $0) != nil }
            .sorted { $0.uuidString < $1.uuidString }
    }

    func toggleCapture(_ device: MediaCaptureState.Device, in tabID: Tab.ID) {
        guard let tab = store.tab(withID: tabID),
              let engine = engineHost.engine(forTabID: tabID, profileID: profileID(for: tab)) as? MediaCaptureProviding
        else { return }
        engine.toggleCapture(device)
    }

    /// How the call card's end button ends a call. A page leaves a meeting
    /// only from its own UI or its media session "hangup" handler, which the
    /// engine exposes only on the call's PiP video (the HANG_UP overlay
    /// button, as on Chrome's video-conferencing PiP). Without it the one
    /// sure way out is taking the page down: ⌘W's close, which archives a
    /// Today tab (Reopen Closed Tab brings it back) and unloads a pinned tab
    /// or favorite, keeping its row. Either drops the page's streams.
    enum CallEndAction: Equatable {
        case hangUp
        case closeTab
        case unloadTab

        static func resolve(canHangUp: Bool, kind: Tab.Kind?, inSplit: Bool) -> CallEndAction? {
            if canHangUp { return .hangUp }
            switch kind {
            case nil: return nil
            case .favorite: return .unloadTab
            case .pinned: return inSplit ? .closeTab : .unloadTab
            case .today: return .closeTab
            }
        }

        var title: String {
            switch self {
            case .hangUp: "Leave Call"
            case .closeTab: "End Call (Close Tab)"
            case .unloadTab: "End Call (Unload Tab)"
            }
        }
    }

    func callEndAction(for tabID: Tab.ID) -> CallEndAction? {
        CallEndAction.resolve(canHangUp: liveVideo(for: tabID)?.canHangUp == true,
                              kind: store.kind(of: tabID),
                              inSplit: store.splitContaining(tabID: tabID) != nil)
    }

    func endCall(_ tabID: Tab.ID) {
        switch callEndAction(for: tabID) {
        case .hangUp?: liveVideo(for: tabID)?.perform(.hangUp)
        case .closeTab?, .unloadTab?: closeTab(tabID)
        case nil: break
        }
    }

    /// The tab whose live video plays in the sidebar, if any.
    func sidebarLiveVideoTabID(in window: SidebarWindowID?) -> Tab.ID? {
        livePlacements.keys.sorted { $0.uuidString < $1.uuidString }.first {
            effectiveLivePlacement(for: $0) == .sidebar && liveVideo(for: $0) != nil
        }
    }

    func liveVideo(for tabID: Tab.ID) -> (any LiveVideoHandle)? {
        guard let tab = store.tab(withID: tabID),
              let engine = engineHost.engine(forTabID: tabID, profileID: profileID(for: tab)) as? LiveVideoProviding
        else { return nil }
        return engine.liveVideo
    }

    /// Where the tab's live video is now: a sidebar placement falls back to
    /// the panel while the sidebar is hidden or mini (the column has no card).
    func effectiveLivePlacement(for tabID: Tab.ID) -> LiveVideoPlacement? {
        livePlacements[tabID]?.effective(sidebarVisible: showsLiveCardInSidebar)
    }

    private var showsLiveCardInSidebar: Bool {
        isSidebarVisible && !isMiniSidebar(in: store.keyWindowID)
    }

    func mediaStripInfo(for tabID: Tab.ID, in window: SidebarWindowID? = nil) -> MediaStripInfo? {
        guard let tab = store.tab(withID: tabID) else { return nil }
        let media = mediaState(for: tabID)
        let video = liveVideo(for: tabID)
        let placement = livePlacements[tabID]
        return MediaStripInfo(
            id: tabID,
            // Arc titles the strip with the tab as the sidebar names it (a
            // renamed tab's own name), not the media session's title.
            title: tab.displayTitle,
            site: tab.url.host() ?? tab.displayTitle,
            location: mediaTabLocation(tab, in: window),
            favicon: favicon(for: tab),
            faviconToken: tab.faviconToken,
            isPlaying: video?.isPlaying ?? media.isPlaying,
            isMuted: isUserMuted(tabID),
            canPreviousTrack: media.canPreviousTrack || video?.canSkipTracks.previous == true,
            canNextTrack: media.canNextTrack || video?.canSkipTracks.next == true,
            offersPictureInPicture: placement?.offersBackToPiP == true
                || (placement == nil && media.canPictureInPicture && !media.isPictureInPicture)
        )
    }

    /// Where a strip's tab lives, so the strip says where to find it: its
    /// space and the folders around it ("Demo › Project C"), a favorite's
    /// Favorites, with the profile first when `window` shows another one.
    func mediaTabLocation(_ tab: Tab, in window: SidebarWindowID?) -> String {
        var parts: [String] = []
        let owner = store.owningProfileID(of: profileID(for: tab))
        if owner != store.owningProfileID(of: space(in: window).profileID), let profile = store.profile(withID: owner) {
            parts.append(profile.name)
        }
        if store.favoriteOwner(of: tab.id) != nil {
            parts.append("Favorites")
        } else {
            if let space = store.spaceContaining(tabID: tab.id).flatMap(store.space(withID:)) { parts.append(space.name) }
            var folders: [String] = []
            var id = store.splitContaining(tabID: tab.id)?.split.id ?? tab.id
            while let folderID = store.parentFolderID(of: id), let folder = store.folder(withID: folderID) {
                folders.insert(folder.title, at: 0)
                id = folderID
            }
            parts += folders
        }
        return parts.joined(separator: " › ")
    }

    /// New live videos start in the sidebar (Video in Sidebar) or the panel;
    /// a tab without one has no placement.
    func reconcileLivePlacements() {
        for (id, media) in mediaStateByTab where media.hasLiveVideo && livePlacements[id] == nil {
            let requested = livePanelRequests.remove(id) != nil
            livePlacements[id] = .initial(embedsInSidebar: embedsVideoInSidebar, requestedPanel: requested)
        }
        for id in livePlacements.keys where mediaStateByTab[id]?.hasLiveVideo != true {
            livePlacements[id] = nil
        }
        for id in blankLiveVideos where livePlacements[id] == nil { blankLiveVideos.remove(id) }
        for id in liveVideoStills.keys where livePlacements[id] == nil { liveVideoStills[id] = nil }
    }

    /// While a view shows `tabID`'s live video: is there a picture? Read back
    /// four times a quarter second apart, a second after it appears and every
    /// two seconds after, while it plays. Hardware-decoded video (YouTube's
    /// VP9 and AV1) has shown black here while the page's own video played;
    /// then the strip stays and the player shows a still of the tab.
    /// The read-back is the compositor's copy of the view, so it sees a
    /// surface that never arrives, not a CALayer that fails to present it.
    /// On the main actor: the engine's read-back aborts off the main thread, and this
    /// model's state is the main thread's (the first build of this crashed the self-test).
    @MainActor
    func watchLiveVideo(_ tabID: Tab.ID) async {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        while !Task.isCancelled {
            if let video = liveVideo(for: tabID), video.isPlaying {
                var samples: [UInt32?] = []
                for index in 0 ..< 4 {
                    if index > 0 { try? await Task.sleep(nanoseconds: 250_000_000) }
                    samples.append(await withCheckedContinuation { done in video.readPixel { done.resume(returning: $0) } })
                }
                guard !Task.isCancelled, liveVideo(for: tabID) === video else { return }
                if LiveVideoDrawing.isBlank(samples) {
                    if blankLiveVideos.insert(tabID).inserted { await takeLiveVideoStill(tabID) }
                } else if blankLiveVideos.contains(tabID) {
                    blankLiveVideos.remove(tabID)
                    liveVideoStills[tabID] = nil
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// The tab's page as it is now, for a blank player's still.
    @MainActor
    private func takeLiveVideoStill(_ tabID: Tab.ID) async {
        guard liveVideoStills[tabID] == nil, let engine = mediaEngine(for: tabID),
              let data = try? await engine.captureSnapshot(scope: .visible), let image = NSImage(data: data) else { return }
        if blankLiveVideos.contains(tabID) { liveVideoStills[tabID] = image }
    }

    // MARK: - Strip buttons

    /// The favicon, title row or a click on the video: show the tab. A live
    /// video ends its session first (Chromium focuses the tab as PiP's back to tab).
    func goToMediaTab(_ tabID: Tab.ID) {
        liveVideo(for: tabID)?.perform(.backToTab)
        showTab(tabID)
    }

    /// Shows a tab wherever it is, as Arc's strip does: another profile's
    /// tab switches profile as the profile menu would, then its space, its
    /// collapsed folders open, a split focuses its pane, and the list scrolls
    /// to its row.
    func showTab(_ tabID: Tab.ID) {
        guard let tab = store.tab(withID: tabID) else { return }
        let owner = store.owningProfileID(of: profileID(for: tab))
        if owner != store.activeOwningProfileID { store.selectProfile(owner) }
        guard store.focusTab(tabID) else { return }
        let row = store.splitContaining(tabID: tabID)?.split.id ?? tabID
        sidebarRowReveal = SidebarReveal(id: row, serial: (sidebarRowReveal?.serial ?? 0) + 1)
        loadSelectedIfNeeded()
    }

    func mediaTogglePlayPause(_ tabID: Tab.ID) {
        if let video = liveVideo(for: tabID) {
            video.perform(.togglePlayPause)
        } else {
            mediaEngine(for: tabID)?.togglePlayPause()
        }
    }

    /// The strip enables a track button when the session or the PiP video
    /// offers it; the press goes to whichever does (the session first).
    func mediaNextTrack(_ tabID: Tab.ID) {
        if !mediaState(for: tabID).canNextTrack, let video = liveVideo(for: tabID), video.canSkipTracks.next {
            video.perform(.nextTrack)
        } else {
            mediaEngine(for: tabID)?.skipToNextTrack()
        }
    }

    func mediaPreviousTrack(_ tabID: Tab.ID) {
        if !mediaState(for: tabID).canPreviousTrack, let video = liveVideo(for: tabID), video.canSkipTracks.previous {
            video.perform(.previousTrack)
        } else {
            mediaEngine(for: tabID)?.skipToPreviousTrack()
        }
    }

    /// "Close Mini Player": hidden until the tab plays again.
    func closeMediaStrip(_ tabID: Tab.ID) {
        if liveVideo(for: tabID) != nil { closeLiveVideo(tabID) }
        mediaControls.dismiss(tabID)
    }

    /// "Open Picture in Picture": a minimized panel comes back; otherwise the
    /// video enters PiP in the floating panel.
    func openPictureInPicture(_ tabID: Tab.ID) {
        if liveVideo(for: tabID) != nil {
            livePlacements[tabID] = .panel
        } else if engineHost.supportsLiveVideo {
            livePanelRequests.insert(tabID)
            setPictureInPicture(true, tabID: tabID)
        } else {
            setPictureInPicture(true, tabID: tabID)
        }
    }

    // MARK: - Live video buttons

    func popOutLiveVideo(_ tabID: Tab.ID) { livePlacements[tabID] = .panel }
    func dockLiveVideo(_ tabID: Tab.ID) { livePlacements[tabID] = .sidebar }
    /// Arc's minimize: the panel collapses into the strip, which offers "Open Picture in Picture".
    func minimizeLiveVideo(_ tabID: Tab.ID) { livePlacements[tabID] = .minimized }

    /// Close (×): the session ends and the video pauses; the paused strip stays.
    func closeLiveVideo(_ tabID: Tab.ID) {
        autoPiPEnteredTabIDs.remove(tabID)
        liveVideo(for: tabID)?.perform(.closeAndPause)
    }

    private func mediaEngine(for tabID: Tab.ID) -> (any WebEngine)? {
        guard let pid = profileID(forTabID: tabID) else { return nil }
        return engineHost.engine(forTabID: tabID, profileID: pid)
    }
}
