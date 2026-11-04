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
