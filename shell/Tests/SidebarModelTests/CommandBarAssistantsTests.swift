import XCTest
@testable import SidebarModel

/// Max › Assistants in the Command Bar (MAX.md §4): shortcuts to each
/// company's own site, the verified prompt addresses, and Add Your Own's checks.
final class CommandBarAssistantsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CommandBarAssistantsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTheBuiltInAssistantsAndTheirAddresses() {
        let byID = Dictionary(uniqueKeysWithValues: CommandBarAssistants.builtIn.map { ($0.id, $0) })
        XCTAssertEqual(byID["chatgpt"]?.template, "https://chatgpt.com/?q=%s")
        XCTAssertEqual(byID["claude"]?.template, "https://claude.ai/new?q=%s")
        XCTAssertEqual(byID["perplexity"]?.template, "https://www.perplexity.ai/search?q=%s")
        XCTAssertEqual(byID["grok"]?.template, "https://grok.com/?q=%s")
        XCTAssertEqual(byID["lechat"]?.template, "https://chat.mistral.ai/chat?q=%s")
        XCTAssertEqual(byID["huggingchat"]?.template, "https://huggingface.co/chat/?prompt=%s")
        for id in ["gemini", "copilot", "deepseek", "kimi"] {
            XCTAssertEqual(byID[id]?.delivery, .clipboard, "\(id) has no prompt address that could be confirmed")
            XCTAssertFalse(byID[id]?.template.contains("%s") ?? true)
        }
        for assistant in CommandBarAssistants.builtIn {
            XCTAssertFalse(assistant.source.isEmpty, "\(assistant.id) says where its address was checked")
            XCTAssertTrue(assistant.template.hasPrefix("https://"))
            if assistant.delivery == .url { XCTAssertTrue(CommandBarAssistants.isValidTemplate(assistant.template), assistant.id) }
        }
        XCTAssertEqual(Set(CommandBarAssistants.builtIn.map(\.keyword)).count, CommandBarAssistants.builtIn.count, "keywords are unique")
    }

    func testNoneIsOnUntilSwitchedAndShortcutsListOnlyTheOnesOn() {
        XCTAssertTrue(CommandBarAssistants.shortcuts(in: defaults).isEmpty)
        CommandBarAssistants.setEnabled("claude", true, in: defaults)
        CommandBarAssistants.setEnabled("deepseek", true, in: defaults)
        let shortcuts = CommandBarAssistants.shortcuts(in: defaults)
        XCTAssertEqual(shortcuts.map(\.keyword), ["claude", "deepseek"], "in the tab's order")
        XCTAssertEqual(shortcuts[0].name, "Claude")
        XCTAssertEqual(shortcuts[0].template, "https://claude.ai/new?q=%s")
        XCTAssertEqual(shortcuts[0].placeholder, "Send a Message…")
        XCTAssertEqual(shortcuts[1].template, "https://chat.deepseek.com/")
        XCTAssertEqual(CommandBarAssistants.assistant(keyword: "CLAUDE", in: defaults)?.id, "claude")
        CommandBarAssistants.setEnabled("claude", false, in: defaults)
        XCTAssertEqual(CommandBarAssistants.enabled(in: defaults).map(\.id), ["deepseek"])
    }

    func testAPromptGoesInTheAddressOrOnTheClipboardNeverIntoThePage() {
        let claude = CommandBarAssistants.builtIn.first { $0.id == "claude" }!
        XCTAssertEqual(claude.action(for: "  what is 2 & 2? #maths  "),
                       .open(URL(string: "https://claude.ai/new?q=what+is+2+%26+2%3F+%23maths")!), "encoded as every site search is")
        let deepSeek = CommandBarAssistants.builtIn.first { $0.id == "deepseek" }!
        XCTAssertEqual(deepSeek.action(for: "hello"), .openCopying(URL(string: "https://chat.deepseek.com/")!, text: "hello"))
        XCTAssertEqual(deepSeek.action(for: "  "), .open(URL(string: "https://chat.deepseek.com/")!))
        XCTAssertEqual(deepSeek.note, "Opens DeepSeek; what you typed is copied, ready to paste.")
    }

    func testAddYourOwnChecksNameKeywordAndTemplate() throws {
        func problem(_ name: String, _ keyword: String, _ template: String) -> CommandBarAssistants.ValidationError? {
            do { _ = try CommandBarAssistants.validate(name: name, keyword: keyword, template: template, existing: []); return nil }
            catch { return error as? CommandBarAssistants.ValidationError }
        }
        XCTAssertNil(problem("Mine", "mine", "https://example.com/ask?q=%s"))
        XCTAssertEqual(problem("", "mine", "https://example.com/?q=%s"), .name)
        XCTAssertEqual(problem(String(repeating: "n", count: 33), "mine", "https://example.com/?q=%s"), .name)
        XCTAssertEqual(problem("Mine", "m", "https://example.com/?q=%s"), .keyword)
        XCTAssertEqual(problem("Mine", "my one", "https://example.com/?q=%s"), .keyword)
        XCTAssertEqual(problem("Mine", "claude", "https://example.com/?q=%s"), .keywordTaken)
        XCTAssertEqual(problem("Mine", "mine", "http://example.com/?q=%s"), .template, "https only")
        XCTAssertEqual(problem("Mine", "mine", "javascript:alert(%s)"), .template)
        XCTAssertEqual(problem("Mine", "mine", "https://example.com/"), .template, "needs its slot")
        XCTAssertEqual(problem("Mine", "mine", "https://example.com/?q=%s&r=%s"), .template, "one slot")
        XCTAssertEqual(problem("Mine", "mine", "https://user:pw@example.com/?q=%s"), .template)
        XCTAssertEqual(problem("Mine", "mine", "https://example.com/?q=%s" + String(repeating: "a", count: 2048)), .template)
        XCTAssertEqual(problem("Mine", "mine", "https:///?q=%s"), .template)
    }

    func testTheirOwnAreSavedCheckedAgainOnLoadAndCapped() throws {
        let mine = try CommandBarAssistants.validate(name: "Mine", keyword: "mine", template: "https://example.com/?q=%s", existing: [])
        try CommandBarAssistants.add(mine, in: defaults)
        XCTAssertEqual(CommandBarAssistants.enabled(in: defaults).map(\.id), ["custom-mine"], "switched on when added")
        XCTAssertThrowsError(try CommandBarAssistants.validate(name: "Again", keyword: "mine", template: "https://e.com/?q=%s",
                                                               existing: CommandBarAssistants.custom(in: defaults)))

        // A hand-edited plist cannot smuggle an unchecked address in.
        var bad = mine
        bad.id = "custom-bad"
        bad.keyword = "bad"
        bad.template = "file:///etc/passwd?%s"
        defaults.set(try JSONEncoder().encode([mine, bad]), forKey: CommandBarAssistants.customKey)
        XCTAssertEqual(CommandBarAssistants.custom(in: defaults).map(\.id), ["custom-mine"])

        defaults.removeObject(forKey: CommandBarAssistants.customKey)
        for index in 0 ..< CommandBarAssistants.maximumCustom {
            try CommandBarAssistants.add(try CommandBarAssistants.validate(name: "A\(index)", keyword: "a\(index)", template: "https://e.com/?q=%s", existing: []), in: defaults)
        }
        let extra = try CommandBarAssistants.validate(name: "Extra", keyword: "extra", template: "https://e.com/?q=%s", existing: [])
        XCTAssertThrowsError(try CommandBarAssistants.add(extra, in: defaults)) { XCTAssertEqual($0 as? CommandBarAssistants.ValidationError, .tooMany) }
        CommandBarAssistants.remove(id: "custom-a0", in: defaults)
        XCTAssertEqual(CommandBarAssistants.custom(in: defaults).count, CommandBarAssistants.maximumCustom - 1)
    }

    func testEachAssistantIsASiteSearchFromItsOwnEntry() throws {
        CommandBarAssistants.setEnabled("chatgpt", true, in: defaults)
        CommandBarAssistants.setEnabled("kimi", true, in: defaults)
        let engines = CommandBarAssistants.siteSearchEngines(in: defaults)
        XCTAssertEqual(engines.map(\.id), ["assistant-chatgpt", "assistant-kimi"])
        let chatGPT = engines[0]
        XCTAssertEqual(chatGPT.source, .assistant)
        XCTAssertEqual(chatGPT.hint, "Ask ChatGPT")
        XCTAssertEqual(chatGPT.placeholder, "Send a Message…")
        XCTAssertEqual(chatGPT.keyword, "chatgpt")
        XCTAssertEqual(chatGPT.aliases, ["gpt"])
        XCTAssertEqual(chatGPT.domain, "chatgpt.com")
        XCTAssertEqual(chatGPT.color, SpaceColor(red: 0x57 / 255, green: 0x9F / 255, blue: 0x8F / 255), "Arc's measured chip")
        XCTAssertEqual(chatGPT.url(for: "what is arc")?.absoluteString, "https://chatgpt.com/?q=what+is+arc")
        XCTAssertNil(chatGPT.clipboardPage)
        let kimi = engines[1]
        XCTAssertEqual(kimi.clipboardPage?.absoluteString, "https://www.kimi.com/")
        XCTAssertNil(kimi.url(for: "hello"), "no address with the text in it")
        XCTAssertEqual(kimi.url(for: ""), kimi.clipboardPage)
        XCTAssertEqual(kimi.domain, "kimi.com")
        XCTAssertEqual(SiteSearchCatalog.match("gpt", in: SiteSearchCatalog.merged(assistants: engines))?.id, "assistant-chatgpt")
    }

    func testTheirOwnUseTheSiteSearchCheckAndArePromptsWithOneSlot() throws {
        let mine = try CommandBarAssistants.validate(name: "Mine", keyword: "mine", template: "https://example.com/ask?q={searchTerms}", existing: [])
        XCTAssertEqual(mine.template, "https://example.com/ask?q=%s", "Chromium's slot spelling is accepted, as for any site search")
        XCTAssertNil(CommandBarAssistants.validatedTemplate("https://example.com/{other}?q=%s"))
        XCTAssertNil(CommandBarAssistants.validatedTemplate("https://ex ample.com/?q=%s"))
        XCTAssertNil(CommandBarAssistants.validatedTemplate("https://%s.example.com/"), "the text never reaches the host")
    }

    func testTurnOnAllEnablesEveryBuiltInAndKeepsTheirOwn() {
        CommandBarAssistants.setEnabled("custom-mine", true, in: defaults)
        CommandBarAssistants.enableAllBuiltIn(in: defaults)
        XCTAssertEqual(CommandBarAssistants.enabledIDs(in: defaults), Set(CommandBarAssistants.builtIn.map(\.id) + ["custom-mine"]))
    }
}
