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

    /// Promotes a live or archived Little Arc into a today tab in the active space.
    @discardableResult
    public func promoteLittleArcToTab(id: LittleArcWindow.ID) -> Tab? {
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
