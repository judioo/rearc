import Foundation
import SidebarModel

/// The Boosts library page (Arc View Boosts, BOOSTS §2, §5): list, create,
/// toggle, rename, duplicate and delete the active profile's boosts. Every
/// change reinstalls the boosts of open tabs through the engines' boost
/// messages (`syncAllTabBoosts`).
extension BrowserViewModel {

    func boostLibraryRows(filter: String = "") -> [BoostLibraryRow] {
        BoostLibraryListing.rows(store.boostLibrary(), currentPage: store.selectedTab?.url, filter: filter)
    }

    var boostsMasterEnabled: Bool { store.boostLibrary().masterEnabled }

    func setBoostsMasterEnabled(_ enabled: Bool) {
        store.setBoostMasterEnabled(enabled)
        syncAllTabBoosts()
    }

    /// A space's own switch (space menu, Edit Space): its open tabs lose or regain their boosts now.
    func setSpaceBoostsEnabled(_ enabled: Bool, for spaceID: Space.ID) {
        store.setSpaceBoostsEnabled(enabled, for: spaceID)
        syncAllTabBoosts()
    }

    func setBoostEnabled(_ packageID: UUID, enabled: Bool) {
        store.setBoostInstallationEnabled(packageID: packageID, enabled: enabled)
        syncAllTabBoosts()
    }

    /// A script boost runs only once its script is allowed (BoostSecurity).
    func setBoostScriptAllowed(_ packageID: UUID, allowed: Bool) {
        store.setBoostScriptUserEnabled(packageID: packageID, enabled: allowed)
        syncAllTabBoosts()
    }

    @discardableResult
    func renameBoost(_ packageID: UUID, to name: String) -> Bool {
        store.renameBoost(packageID: packageID, to: name)
    }

    @discardableResult
    func duplicateBoost(_ packageID: UUID) -> UUID? {
        guard let copy = store.duplicateBoost(packageID: packageID) else { return nil }
        syncAllTabBoosts()
        return copy.manifest.id
    }

    /// Deletes a boost; an editor open on it closes first, discarding its edits.
    func deleteBoost(_ packageID: UUID) {
        if boostEditorDraft?.packageID == packageID {
            cancelBoostEditor()
        }
        for (tabID, draft) in boostEditorDraftByTab where draft.packageID == packageID {
            boostEditorDraftByTab[tabID] = nil
            boostSessionApplyByTab[tabID] = nil
        }
        store.removeBoost(packageID: packageID)
        syncAllTabBoosts()
    }

    /// New Boost from the library: a style boost for `site` (or the page on
    /// screen when `site` is empty). Returns an error message on refusal.
    @discardableResult
    func createBoost(name: String, site: String) -> String? {
        let page: URL
        if site.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let url = store.selectedTab?.url, BoostScopeMatcher.urlIsEligibleForBoosts(url) else {
                return "Enter a site to boost"
            }
            page = url
        } else {
            guard let url = BoostLibraryListing.siteURL(from: site) else { return "“\(site)” is not a site a boost can change" }
            page = url
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Boost for \(page.host() ?? "site")" : trimmed
        guard store.createBoostForCurrentSite(name: title, css: "/* ReArc boost */\n", pageURL: page) != nil else {
            return "Could not create the boost"
        }
        syncAllTabBoosts()
        return nil
    }

    /// Edit from the library: the editor opens on the page on screen, which
    /// the boost must apply to.
    func editBoostFromLibrary(_ packageID: UUID) {
        isBoostLibraryPresented = false
        openBoostEditor(packageID: packageID, startPicker: false)
    }

    /// Opens the boost's first site in a new tab.
    func openBoostSite(_ packageID: UUID) {
        guard let url = boostLibraryRows().first(where: { $0.id == packageID })?.siteURL else { return }
        isBoostLibraryPresented = false
        openInNewTab(url)
    }
}

// MARK: - Legacy boosts and boost files

/// New Legacy Boost (Advanced) and its CSS and JavaScript editor, and
/// boost files (Export…, Import…). Arc shares boosts as links to its own
/// server (BOOSTS §5); ReArc has no server, so a boost travels as a file.
extension BrowserViewModel {

    /// A legacy boost for the page on screen, open in its editor.
    @discardableResult
    func newLegacyBoost() -> String? {
        guard let tab = store.selectedTab, BoostScopeMatcher.urlIsEligibleForBoosts(tab.url) else {
            return "Open a website to boost first"
        }
        let host = tab.url.host() ?? "site"
        guard let created = store.createLegacyBoost(name: "Legacy Boost for \(host)", pageURL: tab.url) else {
            return "Could not create the boost"
        }
        syncAllTabBoosts()
        closeLibrary()
        legacyBoostEditorID = created.manifest.id
        return nil
    }

    /// Edit opens the visual editor for a style boost and the code editor
    /// for a legacy one.
    func editBoost(_ packageID: UUID) {
        if store.boostLibrary().package(id: packageID)?.scriptBoost != nil {
            legacyBoostEditorID = packageID
        } else {
            editBoostFromLibrary(packageID)
        }
    }

    /// Saves the code editor; returns a message when the code is refused.
    func saveLegacyBoost(_ packageID: UUID, css: String, js: String) -> String? {
        let errors = store.updateBoostScript(packageID: packageID, css: css, js: js)
        guard errors.isEmpty else {
            if errors.contains(.remoteImportInCSS) || errors.contains(.remoteScriptSourceInJS) {
                return "Boosts cannot load files from the web."
            }
            if errors.contains(.cssTooLarge) || errors.contains(.jsTooLarge) { return "The boost is too large." }
            return "The boost could not be saved."
        }
        syncAllTabBoosts()
        return nil
    }

    func boostFileData(_ packageID: UUID) -> Data? {
        store.boostLibrary().package(id: packageID).flatMap { try? BoostInterchange.exportJSON($0) }
    }

    /// Adds the boosts in `urls`; a script boost arrives turned off with its
    /// script not allowed. Returns one message per file that was refused.
    @discardableResult
    func importBoostFiles(_ urls: [URL]) -> [String] {
        var problems: [String] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                problems.append("\(url.lastPathComponent): could not be read.")
                continue
            }
            switch BoostInterchange.importJSON(data) {
            case .success(let package):
                if store.importBoostPackage(package) != nil {
                    problems.append("\(url.lastPathComponent): could not be added.")
                }
            case .failure(let error):
                problems.append("\(url.lastPathComponent): \(BoostInterchange.describe(error))")
            }
        }
        syncAllTabBoosts()
        return problems
    }
}
