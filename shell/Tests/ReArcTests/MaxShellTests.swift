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

/// Max › Tidy Tab Titles in the shell: pinning and favoriting tidy by rule,
/// a typed title is never replaced, Undo and Reset Title put it back.
@MainActor
struct MaxTidyTabTitlesShellTests {
    private func setUp(on: Bool = true) -> (BrowserViewModel, Tab) {
        let (model, _) = MaxShellTests.model()
        model.setMaxFeature(.tidyTabTitles, on: on)
        let tab = model.store.addTab(kind: .today, title: "Inbox (3) - you@x.com - Gmail", url: URL(string: "https://mail.google.com/mail/u/0/")!)
        return (model, tab)
    }

    @Test func pinningTidiesTheTitleAndTheToastsUndoPutsItBack() throws {
        let (model, tab) = setUp()
        model.togglePin(tab.id)
        let pinned = try #require(model.store.tab(withID: tab.id))
        #expect(pinned.kind == .pinned)
        #expect(pinned.displayTitle == "Gmail Inbox")
        #expect(pinned.customTitleIsAutomatic)
        #expect(model.toast?.message == "Pinned Tab to “Main” · Title tidied")
        #expect(model.toast?.action == .undo)
        model.runToastUndo()
        #expect(model.store.tab(withID: tab.id)?.customTitle == nil)
        #expect(model.store.tab(withID: tab.id)?.kind == .pinned, "Undo is the title's, not the pin's")
    }

    @Test func offDoesNothing() {
        let (model, tab) = setUp(on: false)
        model.togglePin(tab.id)
        #expect(model.store.tab(withID: tab.id)?.customTitle == nil)
        #expect(model.toast?.message == "Pinned Tab to “Main”")
    }

    @Test func aTypedTitleIsNeverReplaced() {
        let (model, tab) = setUp()
        model.store.renameTab(tab.id, to: "My mail")
        model.togglePin(tab.id)
        #expect(model.store.tab(withID: tab.id)?.displayTitle == "My mail")
        #expect(model.store.tab(withID: tab.id)?.customTitleIsAutomatic == false)
    }

    @Test func undoLeavesARenameMadeSince() throws {
        let (model, tab) = setUp()
        model.store.pinTab(tab.id)
        let undo = try #require(model.tidyTitleIfNeeded(tab.id))
        model.store.renameTab(tab.id, to: "Typed since")
        undo()
        #expect(model.store.tab(withID: tab.id)?.displayTitle == "Typed since")
    }

    @Test func favoritesAreTidiedToo() {
        let (model, tab) = setUp()
        model.addToFavorites(tab.id)
        #expect(model.store.tab(withID: tab.id)?.kind == .favorite)
        #expect(model.store.tab(withID: tab.id)?.displayTitle == "Gmail Inbox")
    }

    @Test func aTabPinnedBeforeItsTitleArrivesIsTidiedWhenItDoes() {
        let (model, _) = setUp()
        let url = URL(string: "https://linear.app/team")!
        let tab = model.store.addTab(kind: .today, title: "linear.app", url: url)
        model.togglePin(tab.id)
        #expect(model.store.tab(withID: tab.id)?.customTitle == nil)
        #expect(model.pendingTitleTidies.contains(tab.id))
        model.handleTabNavigationCommit(tabID: tab.id, url: url, title: "Dashboard | Linear")
        #expect(model.store.tab(withID: tab.id)?.displayTitle == "Linear Dashboard")
        #expect(!model.pendingTitleTidies.contains(tab.id))
    }

    @Test func resetTitleBringsThePagesTitleBack() {
        let (model, tab) = setUp()
        model.togglePin(tab.id)
        model.resetTitle(tab.id)
        #expect(model.store.tab(withID: tab.id)?.displayTitle == "Inbox (3) - you@x.com - Gmail")
    }

    @Test func pinningSeveralTidiesEachAndOneUndoPutsAllBack() {
        let (model, first) = setUp()
        let second = model.store.addTab(kind: .today, title: "Dashboard | Linear", url: URL(string: "https://linear.app/")!)
        model.pinTabs([first.id, second.id])
        #expect(model.store.tab(withID: first.id)?.displayTitle == "Gmail Inbox")
        #expect(model.store.tab(withID: second.id)?.displayTitle == "Linear Dashboard")
        #expect(model.toast?.message == "Pinned 2 Tabs to “Main” · Titles tidied")
        model.runToastUndo()
        #expect(model.store.tab(withID: first.id)?.customTitle == nil)
        #expect(model.store.tab(withID: second.id)?.customTitle == nil)
    }
}
