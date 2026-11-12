import AppKit
import SidebarModel

/// Settings › Max's switches and the assistants list (FEATURE-SPECS/MAX.md).
/// Every feature asks `isMaxFeatureOn` and none needs the tab, so the rows
/// can move to another pane.
extension BrowserViewModel {
    func isMaxFeatureOn(_ feature: MaxFeature) -> Bool {
        maxPreferences.isOn(feature)
    }

    func setMaxFeature(_ feature: MaxFeature, on: Bool) {
        maxPreferences.set(feature, on: on)
    }

    /// Enable Max · Turn On All: every helper, and every built-in assistant.
    func turnOnAllMaxFeatures() {
        maxPreferences.turnOnAll()
        CommandBarAssistants.enableAllBuiltIn(in: externalLinkDefaults)
        assistantsRevision += 1
    }

    var allMaxFeaturesOn: Bool {
        _ = assistantsRevision
        let enabled = CommandBarAssistants.enabledIDs(in: externalLinkDefaults)
        return maxPreferences.allOn && CommandBarAssistants.builtIn.allSatisfy { enabled.contains($0.id) }
    }

    // MARK: Assistants

    var commandBarAssistants: [CommandBarAssistant] {
        _ = assistantsRevision
        return CommandBarAssistants.all(in: externalLinkDefaults)
    }

    /// The command bar's assistants (its site searches): the ones switched on.
    var enabledAssistantSiteSearches: [SiteSearchEngine] {
        _ = assistantsRevision
        return CommandBarAssistants.siteSearchEngines(in: externalLinkDefaults)
    }

    func isAssistantEnabled(_ id: String) -> Bool {
        _ = assistantsRevision
        return CommandBarAssistants.enabledIDs(in: externalLinkDefaults).contains(id)
    }

    func setAssistant(_ id: String, enabled: Bool) {
        CommandBarAssistants.setEnabled(id, enabled, in: externalLinkDefaults)
        assistantsRevision += 1
    }

    /// Add Your Own…: the message to show, or nil when it was added (and switched on).
    func addCustomAssistant(name: String, keyword: String, template: String) -> String? {
        do {
            let existing = CommandBarAssistants.custom(in: externalLinkDefaults)
            let assistant = try CommandBarAssistants.validate(name: name, keyword: keyword, template: template, existing: existing)
            try CommandBarAssistants.add(assistant, in: externalLinkDefaults)
            assistantsRevision += 1
            return nil
        } catch let error as CommandBarAssistants.ValidationError {
            return error.message
        } catch {
            return "Could not save the assistant."
        }
    }

    func removeCustomAssistant(_ id: String) {
        CommandBarAssistants.remove(id: id, in: externalLinkDefaults)
        assistantsRevision += 1
    }
}
