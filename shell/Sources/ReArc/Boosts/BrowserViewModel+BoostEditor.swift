import Foundation
import SidebarModel

extension BrowserViewModel {
    var boostEditorDraft: BoostEditorDraft? {
        guard let tabID = store.selectedTabID else { return nil }
        return boostEditorDraftByTab[tabID]
    }

    var isBoostEditorOpen: Bool { boostEditorDraft != nil }

    func openBoostEditor(packageID: UUID, startPicker: Bool = false) {
        guard let tab = store.selectedTab else { return }
        guard let package = store.boostLibrary().package(id: packageID),
              let css = package.styleBoost?.css else { return }
        let draft = BoostEditorDraft(packageID: packageID, baselineCSS: css, pickerActive: startPicker)
        boostEditorDraftByTab[tab.id] = draft
        boostSessionApplyByTab[tab.id] = BoostSessionApplyMap()
        lastPickedSnapshotByTab[tab.id] = nil
        wireBoostEditorEngine(for: tab)
        if startPicker {
            startBoostPicker()
        } else {
            pushBoostEditorLivePreview(for: tab)
        }
    }

    func toggleBoostPicker() {
        guard let tab = store.selectedTab else { return }
        guard var draft = boostEditorDraftByTab[tab.id] else { return }
        draft.pickerActive.toggle()
        boostEditorDraftByTab[tab.id] = draft
        boostEditorEngine(for: tab)?.setBoostPickerMode(draft.pickerActive)
    }

    func startBoostPicker(zap: Bool = false) {
        guard let tab = store.selectedTab else { return }
        guard var draft = boostEditorDraftByTab[tab.id] else { return }
        draft.pickerActive = true
        draft.zapOnPick = zap
        boostEditorDraftByTab[tab.id] = draft
        boostEditorEngine(for: tab)?.setBoostPickerMode(true)
    }

    func handleBoostPick(_ snapshot: PickedElementSnapshot) {
        guard let tab = store.selectedTab else { return }
        guard var draft = boostEditorDraftByTab[tab.id] else { return }
        let choices = BoostEditorPipeline.topCandidates(from: snapshot, limit: 3)
        draft.candidateChoices = choices
        draft.selectedSelector = choices.first?.candidate.css
        draft.pickerActive = false
        draft.selectorDead = false
        // Zap mode (Arc `appendZap`): the element is hidden at once, previewed live.
        let zapped = draft.zapOnPick ? draft.selectedSelector : nil
        if let zapped { draft.updateVisual { $0.appendZap(zapped) } }
        draft.zapOnPick = false
        boostEditorDraftByTab[tab.id] = draft
        if zapped != nil { pushBoostEditorLivePreview(for: tab) }
        lastPickedSnapshotByTab[tab.id] = snapshot
        boostSelectorFingerprintByTab[tab.id] = BoostSelectorFingerprint.from(snapshot: snapshot)
        boostEditorEngine(for: tab)?.setBoostPickerMode(false)
        if let css = draft.selectedSelector {
            boostEditorEngine(for: tab)?.highlightBoostSelector(css)
        }
    }

    func selectBoostCandidate(at index: Int) {
        guard let tab = store.selectedTab else { return }
        guard var draft = boostEditorDraftByTab[tab.id] else { return }
        guard draft.candidateChoices.indices.contains(index) else { return }
        draft.selectedSelector = draft.candidateChoices[index].candidate.css
        boostEditorDraftByTab[tab.id] = draft
        if let css = draft.selectedSelector {
            boostEditorEngine(for: tab)?.highlightBoostSelector(css)
        }
    }

    /// The drawer's CSS field: the hand-written CSS after the visual block.
    func boostEditorCSSChanged(_ text: String) {
        guard let tab = store.selectedTab else { return }
        guard var draft = boostEditorDraftByTab[tab.id], draft.customCSS != text else { return }
        draft.setCustomCSS(text)
        boostEditorDraftByTab[tab.id] = draft
        schedulePreview(for: tab)
    }

    /// Colour, dark mode, font, text size or a zap changed (Boosts v2).
    func updateBoostVisual(_ change: (inout BoostVisualStyle) -> Void) {
        guard let tab = store.selectedTab else { return }
        guard var draft = boostEditorDraftByTab[tab.id] else { return }
        draft.updateVisual(change)
        boostEditorDraftByTab[tab.id] = draft
        schedulePreview(for: tab)
    }

    private func schedulePreview(for tab: Tab) {
        boostLiveDebounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pushBoostEditorLivePreview(for: tab)
        }
        boostLiveDebounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Zaps the selected element (listed under Zaps, removable).
    func boostQuickHide() {
        guard let selector = boostEditorDraft?.selectedSelector else { return }
        updateBoostVisual { $0.appendZap(selector) }
    }

    /// Zaps every element like the selected one.
    func boostQuickZapSimilar() {
        guard let selector = boostEditorDraft?.selectedSelector else { return }
        updateBoostVisual { $0.appendZap(BoostQuickActions.zapSimilarSelector(selector)) }
    }

    func boostQuickEditStyles() {
        guard let tab = store.selectedTab else { return }
        guard var draft = boostEditorDraftByTab[tab.id] else { return }
        guard let sel = draft.selectedSelector,
              let snap = lastPickedSnapshotByTab[tab.id] else { return }
        let rule = BoostQuickActions.commentedComputedStylesReference(
            selector: sel,
            styles: snap.computedStyles
        )
        draft.setCustomCSS(BoostQuickActions.appendRule(to: draft.customCSS, rule: rule))
        boostEditorDraftByTab[tab.id] = draft
        pushBoostEditorLivePreview(for: tab)
    }

    func saveBoostEditor() {
        guard let tab = store.selectedTab else { return }
        guard let draft = boostEditorDraftByTab[tab.id] else { return }
        guard store.updateBoostStyleCSS(packageID: draft.packageID, css: draft.draftCSS) else { return }
        closeBoostEditor(revert: false)
        syncAllTabBoosts()
    }

    func cancelBoostEditor() {
        closeBoostEditor(revert: true)
    }

    func editBoostFromTabContextMenu() {
        guard let tab = store.selectedTab else { return }
        let matches = store.boostsMatchingPage(tab.url)
        if let first = matches.first {
            openBoostEditor(packageID: first.0.manifest.id, startPicker: false)
            return
        }
        if let created = store.createBoostForCurrentSite(
            name: "Boost for \(tab.url.host() ?? "site")",
            css: "/* ReArc boost */\n",
            pageURL: tab.url
        ) {
            syncAllTabBoosts()
            openBoostEditor(packageID: created.manifest.id, startPicker: true)
        }
    }

    func sessionHealedBoostIDs(for tab: Tab) -> Set<UUID> {
        boostSessionApplyByTab[tab.id]?.healedPackageIDs ?? []
    }

    func runSelectorRepairPipeline(for tab: Tab) {
        guard let draft = boostEditorDraftByTab[tab.id],
              draft.selectorDead,
              let fingerprint = boostSelectorFingerprintByTab[tab.id] else { return }
        boostEditorEngine(for: tab)?.fetchRepairScan { [weak self] scan in
            guard let self else { return }
            let decision = BoostSelectorRepair.considerRepair(fingerprint: fingerprint, scan: scan)
            self.applySessionHeal(for: tab, packageID: draft.packageID, decision: decision)
            if case .stale = decision {
                self.markBoostSelectorDead(for: tab.id)
            } else if case .sessionApply = decision {
                guard var healed = self.boostEditorDraftByTab[tab.id] else { return }
                healed.selectorDead = false
                self.boostEditorDraftByTab[tab.id] = healed
            }
        }
    }

    func applySessionHeal(for tab: Tab, packageID: UUID, decision: BoostSelectorRepairDecision) {
        guard case .sessionApply(let candidate, _) = decision else {
            markBoostSelectorDead(for: tab.id)
            return
        }
        var session = boostSessionApplyByTab[tab.id] ?? BoostSessionApplyMap()
        session.setSessionSelector(storedSelectorKey: packageID, css: candidate.css)
        boostSessionApplyByTab[tab.id] = session
        pushBoostEditorLivePreview(for: tab)
    }

    func markBoostSelectorDead(for tabID: Tab.ID) {
        guard var draft = boostEditorDraftByTab[tabID] else { return }
        draft.selectorDead = true
        boostEditorDraftByTab[tabID] = draft
        if let tab = store.tab(withID: tabID) {
            runSelectorRepairPipeline(for: tab)
        }
    }

    private func closeBoostEditor(revert: Bool) {
        guard let tab = store.selectedTab else { return }
        if revert {
            boostEditorEngine(for: tab)?.clearEditorLiveCSS()
        }
        let editor = boostEditorEngine(for: tab)
        editor?.setBoostEditorOpen(false)
        editor?.onBoostEditorPick = nil
        editor?.onBoostEditorCancel = nil
        boostEditorDraftByTab[tab.id] = nil
        boostSessionApplyByTab[tab.id] = nil
        lastPickedSnapshotByTab[tab.id] = nil
        boostSelectorFingerprintByTab[tab.id] = nil
        boostLiveDebounceWorkItem?.cancel()
        if !revert {
            boostEditorEngine(for: tab)?.clearEditorLiveCSS()
        }
    }

    private func pushBoostEditorLivePreview(for tab: Tab) {
        guard let draft = boostEditorDraftByTab[tab.id] else { return }
        let entries = store.activeBoostEntries(for: tab)
        let session = boostSessionApplyByTab[tab.id] ?? BoostSessionApplyMap()
        let css = BoostEditorLiveApply.liveStylesheet(
            installedEntries: entries,
            editingPackageID: draft.packageID,
            draftCSS: draft.draftCSS,
            sessionMap: session
        )
        boostEditorEngine(for: tab)?.applyEditorLiveCSS(css)
    }

    private func wireBoostEditorEngine(for tab: Tab) {
        guard let editor = boostEditorEngine(for: tab) else { return }
        editor.setBoostEditorOpen(true)
        editor.onBoostEditorPick = { [weak self] snap in
            self?.handleBoostPick(snap)
        }
        editor.onBoostEditorCancel = { [weak self, weak editor] in
            guard let self, var draft = self.boostEditorDraftByTab[tab.id] else { return }
            draft.pickerActive = false
            draft.zapOnPick = false
            self.boostEditorDraftByTab[tab.id] = draft
            editor?.setBoostPickerMode(false)
        }
    }

    /// The selected tab's engine when it can drive the editor (WebKit, or Chromium with script_evaluation).
    private func boostEditorEngine(for tab: Tab) -> (any BoostEditorEngine)? {
        let pid = profileID(for: tab)
        guard let editor = engineHost.engine(for: tab, profileID: pid) as? any BoostEditorEngine,
              editor.supportsBoostEditor else { return nil }
        return editor
    }
}
