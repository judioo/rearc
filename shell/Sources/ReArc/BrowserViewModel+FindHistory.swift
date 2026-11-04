import AppKit
import SidebarModel

/// Find in page (Cmd+F, Cmd+G, Shift+Cmd+G), the command bar's visit
/// history and the downloads tray toggle.
extension BrowserViewModel {

    // MARK: - Find in page

    /// The page find acts on: the key private window's, else the focused tab's
    /// (the focused pane in a split).
    var findTargetEngine: (any FindInPageEngine)? {
        (keyPrivateWindow?.engine ?? focusedEngine) as? FindInPageEngine
    }

    /// Cmd+F: open the bar on the key page, or refocus it.
    func showFindBar() {
        guard let engine = findTargetEngine else { return }
        findBar.present(on: engine)
    }

    /// Cmd+G / Shift+Cmd+G: repeat the last search on the key page; opens
    /// the bar when it is closed or showing another page.
    func findNext(forward: Bool) {
        guard let engine = findTargetEngine else { return }
        let target = engine as AnyObject
        if !findBar.isPresented || findBar.engine.map({ ($0 as AnyObject) !== target }) ?? true {
            findBar.present(on: engine)
            return
        }
        findBar.next(forward: forward)
    }

    func closeFindBar() {
        findBar.close()
    }

    // MARK: - Visit history (command bar)

    /// Files saved next to the sidebar file: `History.json` beside the default
    /// `sidebar.json`, `<name>-History.json` beside any other (tests).
    static func siblingFile(_ name: String, of sidebarFile: URL) -> URL {
        let base = sidebarFile.deletingPathExtension().lastPathComponent
        let directory = sidebarFile.deletingLastPathComponent()
        return directory.appendingPathComponent(base == "sidebar" ? name : "\(base)-\(name)")
    }

    /// A sidebar tab committed or finished loading `url`. The commit and the
    /// load stop of one navigation count once; the later title replaces the
    /// commit's.
    func recordVisit(tabID: Tab.ID, url: URL, title: String?, at date: Date = Date()) {
        guard let key = VisitHistory.key(for: url) else { return }
        if lastRecordedVisit[tabID] == key {
            if let title, !title.isEmpty { visitHistory.updateTitle(url: url, title: title) }
        } else {
            lastRecordedVisit[tabID] = key
            visitHistory.recordVisit(url: url, title: title, at: date)
        }
        scheduleVisitHistorySave()
    }

    func clearVisitHistory() {
        visitHistory.removeAll()
        lastRecordedVisit = [:]
        scheduleVisitHistorySave()
    }

    func removeFromVisitHistory(_ url: URL) {
        visitHistory.remove(url: url)
        scheduleVisitHistorySave()
    }

    func scheduleVisitHistorySave() {
        historySaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveVisitHistory() }
        historySaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveVisitHistory() {
        historySaveWorkItem?.cancel()
        historySaveWorkItem = nil
        guard let historyFileURL else { return }
        do {
            try VisitHistoryFile.save(visitHistory, to: historyFileURL)
        } catch {
            FileHandle.standardError.write(Data("[ReArc] could not save \(historyFileURL.lastPathComponent): \(error.localizedDescription)\n".utf8))
        }
    }

    // MARK: - Downloads

    func toggleDownloadsTray() {
        downloads.isTrayPresented.toggle()
    }

    /// The tray shows in one window: the key browser window (or the only one).
    func isKeyBrowserWindow(_ window: SidebarWindowID?) -> Bool {
        store.keyWindowID == nil || window == nil || store.keyWindowID == window
    }
}
