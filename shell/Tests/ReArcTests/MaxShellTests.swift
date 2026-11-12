import Foundation
import Testing
import SidebarModel
@testable import ReArc

/// Settings › Max in the shell (FEATURE-SPECS/MAX.md): its wording, Turn On
/// All, and each helper's wiring.
@MainActor
struct MaxShellTests {
    static func model(spaces: [Space] = [Space(name: "Main")]) -> (BrowserViewModel, UserDefaults) {
        let model = BrowserViewModel(store: SidebarStore(spaces: spaces),
                                     persistence: SidebarFilePersistence(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("max-\(UUID().uuidString).json")),
                                     faviconStore: FaviconStore(directory: nil))
        let defaults = UserDefaults(suiteName: "MaxShellTests.\(UUID().uuidString)")!
        model.externalLinkDefaults = defaults
        model.maxPreferences = MaxPreferences()
        return (model, defaults)
    }

    @Test func theTabSaysPlainlyThatNothingHereIsAI() {
        #expect(MaxSettingsPane.intro == "Small scripted helpers. No AI: they follow fixed rules on this Mac and send nothing.")
        #expect(MaxSettingsPane.assistantsIntro.contains("only a shortcut to that company’s own site"))
        #expect(MaxSettingsPane.assistantsIntro.contains("ReArc itself runs no AI"))
        #expect(MaxSettingsPane.footer == "These run on this Mac. Nothing is sent.")
        #expect(MaxSettingsPane.assistantsFooter == "An assistant opens its own site with what you typed.")
        #expect(MaxSettingsPane.helperRows == [.tidyTabs, .instantLinks, .tidyTabTitles, .tidyDownloads])
    }

    @Test func turnOnAllTurnsOnEveryHelperAndEveryBuiltInAssistant() {
        let (model, defaults) = Self.model()
        #expect(!model.allMaxFeaturesOn)
        model.turnOnAllMaxFeatures()
        #expect(model.allMaxFeaturesOn)
        for feature in MaxFeature.allCases { #expect(model.isMaxFeatureOn(feature)) }
        #expect(CommandBarAssistants.enabled(in: defaults).map(\.id) == CommandBarAssistants.builtIn.map(\.id))
        #expect(MaxPreferences.load(from: defaults).allOn, "saved to the model's defaults")
        model.setMaxFeature(.tidyTabs, on: false)
        #expect(!model.allMaxFeaturesOn)
    }

    @Test func addYourOwnValidatesAndSwitchesItOn() {
        let (model, defaults) = Self.model()
        #expect(model.addCustomAssistant(name: "Mine", keyword: "mine", template: "http://example.com/?q=%s")
            == CommandBarAssistants.ValidationError.template.message)
        #expect(model.addCustomAssistant(name: "Mine", keyword: "mine", template: "https://example.com/?q=%s") == nil)
        #expect(model.isAssistantEnabled("custom-mine"))
        #expect(model.commandBarAssistants.last?.name == "Mine")
        model.removeCustomAssistant("custom-mine")
        #expect(CommandBarAssistants.custom(in: defaults).isEmpty)
        #expect(!model.isAssistantEnabled("custom-mine"))
    }
}
