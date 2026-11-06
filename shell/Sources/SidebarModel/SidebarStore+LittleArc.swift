import Foundation

extension SidebarStore {

    // MARK: - Little Arc state

    public var littleArcLiveWindows: [LittleArcWindow] {
        littleArcWindows
    }

    public var littleArcArchivedWindows: [ArchivedLittleArcWindow] {
        archivedLittleArcWindows
    }

    public func littleArcWindow(withID id: LittleArcWindow.ID) -> LittleArcWindow? {
        littleArcWindows.first(where: { $0.id == id })
    }

    @discardableResult
    public func createLittleArcWindow(
        id: LittleArcWindow.ID = UUID(),
        url: URL,
        title: String? = nil,
        profileID: Profile.ID? = nil,
        at date: Date = Date()
    ) -> LittleArcWindow {
        let resolvedTitle = title ?? url.host() ?? url.absoluteString
        let originProfile = profileID ?? activeProfileID
        let window = LittleArcWindow(
            id: id,
            url: url,
            title: resolvedTitle,
            profileID: originProfile,
            createdAt: date,
            lastActiveAt: date
        )
        littleArcWindows.append(window)
        notifyMutation()
        return window
    }

    public func touchLittleArcWindow(id: LittleArcWindow.ID, at date: Date = Date()) {
        guard let index = littleArcWindows.firstIndex(where: { $0.id == id }) else { return }
        littleArcWindows[index].lastActiveAt = date
        notifyMutation()
    }

    public func updateLittleArcWindow(id: LittleArcWindow.ID, title: String?, url: URL?) {
        guard let index = littleArcWindows.firstIndex(where: { $0.id == id }) else { return }
        if let title { littleArcWindows[index].title = title }
        if let url { littleArcWindows[index].url = url }
        notifyMutation()
    }

    @discardableResult
    public func archiveLittleArcWindow(
        id: LittleArcWindow.ID,
        at date: Date = Date(),
        reason: LittleArcArchiveReason
    ) -> ArchivedLittleArcWindow? {
        guard let index = littleArcWindows.firstIndex(where: { $0.id == id }) else { return nil }
        let window = littleArcWindows.remove(at: index)
        let archived = ArchivedLittleArcWindow(window: window, archivedAt: date, reason: reason)
        archivedLittleArcWindows.append(archived)
        notifyMutation()
        return archived
    }

    /// Where Open in <Space> puts a Little Arc's page (Arc's toolbar names it):
    /// the active space, which follows the last focused browser window, when it
    /// shares the Little Arc's profile; otherwise that profile's last space.
    public func littleArcTargetSpace(for id: LittleArcWindow.ID) -> Space? {
        guard let profileID = littleArcWindows.first(where: { $0.id == id })?.profileID
            ?? archivedLittleArcWindows.first(where: { $0.window.id == id })?.window.profileID else { return nil }
        if activeSpace.profileID == profileID { return activeSpace }
        let candidates = spaces(in: profileID)
        if let remembered = lastActiveSpaceByProfile[profileID],
           let space = candidates.first(where: { $0.id == remembered }) {
            return space
        }
        return candidates.first
    }

    /// Promotes a live or archived Little Arc into a today tab in `spaceID`
    /// (a space of the window's profile), or in the target space above.
    @discardableResult
    public func promoteLittleArcToTab(id: LittleArcWindow.ID, into spaceID: Space.ID? = nil) -> Tab? {
        let window: LittleArcWindow
        if let live = littleArcWindows.first(where: { $0.id == id }) {
            window = live
            littleArcWindows.removeAll { $0.id == id }
        } else if let archivedIndex = archivedLittleArcWindows.firstIndex(where: { $0.id == id }) {
            window = archivedLittleArcWindows.remove(at: archivedIndex).window
        } else {
            return nil
        }
        if window.profileID != activeProfileID {
            selectProfile(window.profileID)
        }
        if let spaceID, space(withID: spaceID)?.profileID == window.profileID {
            selectSpace(spaceID)
        }
        let tab = addTab(kind: .today, title: window.title, url: window.url, in: activeSpaceID)
        selectTab(tab.id)
        notifyMutation()
        return tab
    }

    /// Auto-archives idle live windows; returns ids archived.
    @discardableResult
    public func autoArchiveIdleLittleArcWindows(referenceDate: Date = Date()) -> [LittleArcWindow.ID] {
        let ids = LittleArcPolicy.windowsEligibleForAutoArchive(live: littleArcWindows, referenceDate: referenceDate)
        for id in ids {
            archiveLittleArcWindow(id: id, at: referenceDate, reason: .auto)
        }
        return ids
    }
}
