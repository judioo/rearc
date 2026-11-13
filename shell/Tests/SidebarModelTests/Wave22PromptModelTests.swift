import XCTest
@testable import SidebarModel

/// Wave 22: the pure models behind JavaScript dialogs, file choosers,
/// permission prompts, the page context menu and password offers.
final class Wave22PromptModelTests: XCTestCase {

    // MARK: Dialogs

    func testDialogTextFollowsChrome() {
        let alert = JavaScriptDialogRequest(id: 1, kind: .alert, message: "Hi", origin: "https://www.example.com")
        XCTAssertEqual(alert.title, "example.com says")
        XCTAssertEqual(alert.acceptTitle, "OK")
        XCTAssertFalse(alert.showsCancel)
        XCTAssertFalse(alert.showsTextField)

        let opaque = JavaScriptDialogRequest(id: 2, kind: .confirm, message: "Sure?", origin: "null")
        XCTAssertEqual(opaque.title, "This page says")
        XCTAssertTrue(opaque.showsCancel)

        let port = JavaScriptDialogRequest(id: 3, kind: .prompt, message: "Name", defaultText: "x", origin: "http://127.0.0.1:8080")
        XCTAssertEqual(port.title, "http://127.0.0.1:8080 says")
        XCTAssertTrue(port.showsTextField)

        let leave = JavaScriptDialogRequest(id: 4, kind: .beforeUnload, message: "ignored", origin: "https://a.test")
        XCTAssertEqual(leave.title, "Leave site?")
        XCTAssertEqual(leave.acceptTitle, "Leave")
        XCTAssertEqual(leave.displayMessage, "Changes you made may not be saved.")
        var reload = leave
        reload.isReload = true
        XCTAssertEqual(reload.title, "Reload site?")
        XCTAssertEqual(reload.acceptTitle, "Reload")

        let long = JavaScriptDialogRequest(id: 5, kind: .alert, message: String(repeating: "a", count: 20_000), origin: "")
        XCTAssertEqual(long.displayMessage.count, JavaScriptDialogRequest.maxMessageLength + 1)
    }

    func testPromptReplyIsClippedToTheABILimitOnACharacterBoundary() {
        XCTAssertEqual(JavaScriptDialogReply.prompt("short"), JavaScriptDialogReply(accept: true, text: "short"))
        let emoji = String(repeating: "😀", count: JavaScriptDialogReply.maxTextBytes / 4 + 10)
        let clipped = JavaScriptDialogReply.prompt(emoji)
        XCTAssertTrue(clipped.accept)
        XCTAssertLessThanOrEqual(clipped.text?.utf8.count ?? .max, JavaScriptDialogReply.maxTextBytes)
        XCTAssertEqual(clipped.text?.utf8.count, JavaScriptDialogReply.maxTextBytes)
        XCTAssertTrue(clipped.text?.allSatisfy { $0 == "😀" } ?? false)
    }

    func testDialogGuardOffersSuppressionFromTheSecondDialog() {
        var guardState = JavaScriptDialogGuard()
        XCTAssertEqual(guardState.admit(.alert), .present(offersSuppression: false))
        XCTAssertEqual(guardState.admit(.confirm), .present(offersSuppression: true))
        // Leave-site prompts are not counted and never offer it.
        XCTAssertEqual(guardState.admit(.beforeUnload), .present(offersSuppression: false))
        XCTAssertEqual(guardState.shownCount, 2)

        guardState.suppress()
        XCTAssertEqual(guardState.admit(.alert), .suppress(JavaScriptDialogReply(accept: true)))
        XCTAssertEqual(guardState.admit(.confirm), .suppress(JavaScriptDialogReply(accept: false)))
        XCTAssertEqual(guardState.admit(.prompt), .suppress(JavaScriptDialogReply(accept: false)))
        // A suppressed page can always be left.
        XCTAssertEqual(guardState.admit(.beforeUnload), .suppress(JavaScriptDialogReply(accept: true)))
        XCTAssertEqual(guardState.suppressedCount, 4)

        guardState.reset()
        XCTAssertFalse(guardState.isSuppressed)
        XCTAssertEqual(guardState.admit(.alert), .present(offersSuppression: false))
    }

    // MARK: File chooser

    func testAcceptListSplitsIntoExtensionsAndMIMETypes() {
        let filter = FileTypeFilter(acceptTypes: [".PDF", "image/*", " .png ", "application/json", ".pdf", "", "txt"])
        XCTAssertEqual(filter.extensions, ["pdf", "png", "txt"])
        XCTAssertEqual(filter.mimeTypes, ["image/*", "application/json"])
        XCTAssertTrue(FileTypeFilter(acceptTypes: []).isEmpty)
    }

    func testChooserModesMapToPanelBehavior() {
        let open = FileChooserRequest(id: 1, mode: .open, origin: "https://up.example")
        XCTAssertFalse(open.allowsMultipleSelection)
        XCTAssertFalse(open.choosesDirectories)
        XCTAssertEqual(open.prompt, "Open")
        XCTAssertEqual(open.message, "Choose a file to upload to up.example.")
        XCTAssertTrue(FileChooserRequest(id: 2, mode: .openMultiple).allowsMultipleSelection)
        let folder = FileChooserRequest(id: 3, mode: .uploadFolder, origin: "https://up.example")
        XCTAssertTrue(folder.choosesDirectories)
        XCTAssertEqual(folder.prompt, "Upload")
        XCTAssertTrue(folder.message?.contains("Every file in it") ?? false)
        XCTAssertTrue(FileChooserRequest(id: 4, mode: .openDirectory).choosesDirectories)
        let titled = FileChooserRequest(id: 5, mode: .open, origin: "https://up.example", title: "Pick a photo")
        XCTAssertEqual(titled.message, "Pick a photo")

        let save = FileChooserRequest(id: 6, mode: .save, defaultPath: "/Users/me/Downloads/report.pdf")
        XCTAssertTrue(save.isSave)
        XCTAssertEqual(save.prompt, "Save")
        XCTAssertEqual(save.saveDefaults(fallbackDirectory: "/tmp").directory, "/Users/me/Downloads")
        XCTAssertEqual(save.saveDefaults(fallbackDirectory: "/tmp").fileName, "report.pdf")
        let bare = FileChooserRequest(id: 7, mode: .save, defaultPath: "report.pdf")
        XCTAssertEqual(bare.saveDefaults(fallbackDirectory: "/tmp").directory, "/tmp")
        XCTAssertEqual(bare.saveDefaults(fallbackDirectory: "/tmp").fileName, "report.pdf")
    }

    func testRepliesAreOnlyWhatTheABIAccepts() {
        XCTAssertEqual(FileChooserReply.validPaths(["/a/b.txt"], mode: .open), ["/a/b.txt"])
        XCTAssertNil(FileChooserReply.validPaths([], mode: .open))
        XCTAssertNil(FileChooserReply.validPaths(["relative.txt"], mode: .open))
        XCTAssertNil(FileChooserReply.validPaths(["/a/../etc/passwd"], mode: .open))
        XCTAssertEqual(FileChooserReply.validPaths(["/a/..b/c"], mode: .open), ["/a/..b/c"])
        XCTAssertNil(FileChooserReply.validPaths(["/a", "/b"], mode: .open))
        XCTAssertNil(FileChooserReply.validPaths(["/a", "/b"], mode: .uploadFolder))
        XCTAssertEqual(FileChooserReply.validPaths(["/a", "/b"], mode: .openMultiple), ["/a", "/b"])
        XCTAssertNil(FileChooserReply.validPaths(["/" + String(repeating: "x", count: FileChooserReply.maxPathBytes)], mode: .open))
    }

    // MARK: Permissions

    func testPermissionWording() {
        let media = PermissionPromptRequest(id: 1, origin: "https://meet.example", types: [.camera, .microphone])
        XCTAssertEqual(media.host, "meet.example")
        XCTAssertEqual(media.phrases, ["Use your camera and microphone"])
        XCTAssertEqual(media.symbol, "video.fill")
        XCTAssertTrue(media.needsSystemAuthorization)
        XCTAssertNil(media.embeddedNote)

        let embedded = PermissionPromptRequest(id: 2, origin: "https://maps.example", embeddingOrigin: "https://blog.example", types: [.geolocation])
        XCTAssertEqual(embedded.phrases, ["Know your location"])
        XCTAssertEqual(embedded.embeddedNote, "Embedded in blog.example")

        let notify = PermissionPromptRequest(id: 3, origin: "https://news.example", types: [.notifications])
        XCTAssertFalse(notify.needsSystemAuthorization)
        XCTAssertEqual(notify.symbol, "bell.fill")
        XCTAssertEqual(PermissionType("window_management").phrase, "Manage windows on all your displays")
        XCTAssertEqual(PermissionType("something_new").phrase, "Use something new")
        XCTAssertEqual(PermissionType("something_new").name, "Something new")
    }

    func testSitePermissionStoreRemembersOnlyPersistedAnswers() throws {
        var store = SitePermissionStore()
        let scope = UUID().uuidString
        let site = "https://meet.example"
        store.record(.allow, remembered: true, types: [.camera, .microphone], origin: site, scope: scope)
        store.record(.deny, remembered: false, types: [.notifications], origin: site, scope: scope)
        store.record(.dismiss, remembered: true, types: [.geolocation], origin: site, scope: scope)
        XCTAssertEqual(store.entries(origin: site, scope: scope).map(\.type.name), ["Camera", "Microphone", "Notifications"])
        XCTAssertEqual(store.rememberedDecision(for: [.camera, .microphone], origin: site, scope: scope), .allow)
        XCTAssertNil(store.rememberedDecision(for: [.notifications], origin: site, scope: scope), "this-time answers are not replayed")
        XCTAssertNil(store.rememberedDecision(for: [.camera, .geolocation], origin: site, scope: scope))
        XCTAssertNil(store.rememberedDecision(for: [.camera], origin: site, scope: "other"))

        let privateScope = SitePermissionStore.ephemeralPrefix + UUID().uuidString
        store.record(.allow, remembered: true, types: [.camera], origin: site, scope: privateScope)
        let saved = store.persistable
        XCTAssertEqual(saved.entries(origin: site, scope: scope).map(\.type.key), ["camera_stream", "mic_stream"])
        XCTAssertTrue(saved.entries(origin: site, scope: privateScope).isEmpty)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w22-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try store.save(to: url)
        let loaded = SitePermissionStore.load(from: url)
        XCTAssertEqual(loaded.rememberedDecision(for: [.camera], origin: site, scope: scope), .allow)
        XCTAssertTrue(SitePermissionStore.load(from: url.appendingPathExtension("missing")).scopes.isEmpty)

        store.reset(origin: site, scope: scope, type: .camera)
        XCTAssertNil(store.rememberedDecision(for: [.camera], origin: site, scope: scope))
        XCTAssertEqual(store.rememberedDecision(for: [.microphone], origin: site, scope: scope), .allow)
        store.reset(origin: site, scope: scope)
        XCTAssertTrue(store.entries(origin: site, scope: scope).isEmpty)
        store.dropScope(privateScope)
        XCTAssertTrue(store.scopes.isEmpty)
    }

    func testOriginHelpers() {
        XCTAssertEqual(PageOrigin.of(URL(string: "https://Example.com/a?b")!), "https://example.com")
        XCTAssertEqual(PageOrigin.of(URL(string: "http://127.0.0.1:8080/x")!), "http://127.0.0.1:8080")
        XCTAssertNil(PageOrigin.of(URL(string: "data:text/html,hi")!))
        XCTAssertNil(PageOrigin.displayHost(""))
        XCTAssertEqual(BrowserInternalPage.siteDetailsURL(origin: "https://a.test:8443")?.absoluteString,
                       "chrome://settings/content/siteDetails?site=https://a.test:8443")
        XCTAssertEqual(URLEntry.searchURL(for: "red pandas")?.absoluteString, "https://duckduckgo.com/?q=red%20pandas")
    }

    // MARK: Context menu

    private let options = PageContextMenuPlan.Options(canGoBack: true, canGoForward: false, canViewSource: true)

    func testLinkMenuHasArcDestinationsAndCopyLink() {
        let plan = PageContextMenuPlan.plan(for: PageContextMenuParams(linkURL: "https://a.test/x", pageURL: "https://a.test/"), options: options)
        XCTAssertEqual(plan.items, [.openLinkInNewTab, .openLinkInNewWindow, .openLinkInNewSplit, .openLinkInLittleArc,
                                    .openLinkInPrivateWindow, .copyLink, .inspect])
        XCTAssertEqual(plan.entry(.inspect)?.isEnabled, false, "inspect is unsupported until an engine offers it")
        XCTAssertEqual(plan.sections.count, 3)

        var noExtras = options
        noExtras.canOpenLittleArc = false
        noExtras.canOpenSplit = false
        noExtras.canOpenWindow = false
        noExtras.canOpenPrivateWindow = false
        noExtras.showsDisabledInspect = false
        XCTAssertEqual(PageContextMenuPlan.plan(for: PageContextMenuParams(linkURL: "https://a.test/x"), options: noExtras).items,
                       [.openLinkInNewTab, .copyLink])
        var inspect = noExtras
        inspect.canInspect = true
        XCTAssertEqual(PageContextMenuPlan.plan(for: PageContextMenuParams(), options: inspect).entry(.inspect)?.isEnabled, true)
    }

    func testUnopenableLinksGetNoLinkItems() {
        let plan = PageContextMenuPlan.plan(for: PageContextMenuParams(linkURL: "javascript:alert(1)"), options: options)
        XCTAssertFalse(plan.items.contains(.openLinkInNewTab))
        XCTAssertFalse(plan.items.contains(.copyLink))
        XCTAssertTrue(plan.items.contains(.back), "falls back to the page menu")
    }

    func testImageMenu() {
        let params = PageContextMenuParams(srcURL: "https://a.test/cat.png", mediaType: .image, hasImageContents: true)
        let plan = PageContextMenuPlan.plan(for: params, options: options)
        XCTAssertEqual(plan.items, [.openImageInNewTab, .saveImage, .copyImage, .copyImageAddress, .inspect])
        XCTAssertEqual(plan.entry(.saveImage)?.isEnabled, true)
        let canvas = PageContextMenuPlan.plan(for: PageContextMenuParams(mediaType: .canvas, hasImageContents: false), options: options)
        XCTAssertEqual(canvas.items, [.saveImage, .copyImage, .inspect])
        XCTAssertEqual(canvas.entry(.saveImage)?.isEnabled, false)
        let drawn = PageContextMenuPlan.plan(for: PageContextMenuParams(mediaType: .canvas, hasImageContents: true),
                                             options: PageContextMenuPlan.Options(imageSearchName: "Google"))
        XCTAssertEqual(drawn.items, [.saveImage, .copyImage, .inspect], "a canvas has no address to open, copy or search")
        XCTAssertEqual(drawn.entry(.saveImage)?.isEnabled, true)
    }

    /// The owner's case: tenor's GIF inside an `<a>` to another site. Arc's
    /// link section, then its image section, each item enabled.
    func testLinkedImageMenuFollowsArc() {
        let params = PageContextMenuParams(
            linkURL: "https://itunes.apple.com/app/tenor", srcURL: "https://c.tenor.com/HR3YZjYlr_UAAAAC/tenor.gif",
            pageURL: "https://media1.tenor.com/m/HR3YZjYlr_UAAAAC/nervous.gif", mediaType: .image, hasImageContents: true
        )
        var arc = options
        arc.canSaveLink = true
        arc.imageSearchName = "Google"
        let plan = PageContextMenuPlan.plan(for: params, options: arc)
        XCTAssertEqual(plan.sections.map { $0.map(\.item) }, [
            [.openLinkInNewTab, .openLinkInNewWindow, .openLinkInNewSplit, .openLinkInLittleArc, .openLinkInPrivateWindow],
            [.saveLinkAs, .copyLink],
            [.openImageInNewTab, .saveImage, .copyImage, .copyImageAddress, .searchImage("Google")],
            [.inspect],
        ])
        XCTAssertTrue(plan.sections.dropLast().joined().allSatisfy(\.isEnabled))
        XCTAssertEqual(plan.items.map(\.title), [
            "Open Link in New Tab", "Open Link in New Window", "Open Link in Split View", "Open Link in Little ReArc",
            "Open Link in Private Window", "Save Link As…", "Copy Link Address", "Open Image in New Tab", "Save Image As…",
            "Copy Image", "Copy Image Address", "Search Google for Image", "Inspect",
        ])
        // Without the engine's Save Link As (before ABI 1.64) the item is left out, not shown dead.
        XCTAssertEqual(PageContextMenuPlan.plan(for: params, options: options).sections[1].map(\.item), [.copyLink])
        // An image still loading (no contents yet) cannot be saved or copied; its address can.
        var loading = params
        loading.hasImageContents = false
        let pending = PageContextMenuPlan.plan(for: loading, options: arc)
        XCTAssertEqual(pending.entry(.saveImage)?.isEnabled, false)
        XCTAssertEqual(pending.entry(.copyImage)?.isEnabled, false)
        XCTAssertEqual(pending.entry(.copyImageAddress)?.isEnabled, true)
    }

    func testImageWithoutAnOpenableAddress() {
        var arc = options
        arc.imageSearchName = "Google"
        // No src (a large data: image Blink leaves out): save and copy run on the pixels.
        let noSource = PageContextMenuPlan.plan(for: PageContextMenuParams(mediaType: .image, hasImageContents: true), options: arc)
        XCTAssertEqual(noSource.items, [.saveImage, .copyImage, .inspect])
        // data: and blob: images are not opened, copied as addresses or searched.
        for src in ["data:image/gif;base64,R0lGODlhAQABAAAAACw=", "blob:https://a.test/1234", "file:///tmp/a.gif"] {
            let plan = PageContextMenuPlan.plan(for: PageContextMenuParams(srcURL: src, mediaType: .image, hasImageContents: true), options: arc)
            XCTAssertEqual(plan.items, [.saveImage, .copyImage, .inspect], src)
        }
    }

    func testImageSearchFollowsTheDefaultEngine() {
        let image = URL(string: "https://c.tenor.com/HR3YZjYlr_UAAAAC/tenor.gif?a=1&b=2")!
        XCTAssertEqual(SearchProvider.google.imageSearchURL(for: image)?.absoluteString,
                       "https://lens.google.com/uploadbyurl?url=https%3A%2F%2Fc.tenor.com%2FHR3YZjYlr_UAAAAC%2Ftenor.gif%3Fa%3D1%26b%3D2")
        XCTAssertEqual(SearchProvider.bing.imageSearchURL(for: image)?.host(), "www.bing.com")
        XCTAssertTrue(SearchProvider.google.searchesByImage && SearchProvider.bing.searchesByImage)
        for provider in [SearchProvider.duckDuckGo, .ecosia, .brave] {
            XCTAssertFalse(provider.searchesByImage, provider.name)
            XCTAssertNil(provider.imageSearchURL(for: image), provider.name)
        }
        // Chromium's engines come with their own ids; the template's host decides.
        let chromiumGoogle = SearchProvider(id: "7", name: "Google", keyword: "google.com",
                                            searchTemplate: "https://www.google.co.uk/search?q=%s&ie=UTF-8")
        XCTAssertTrue(chromiumGoogle.searchesByImage)
        let lookalike = SearchProvider(id: "8", name: "Google", keyword: "x", searchTemplate: "https://google.evil.test/?q=%s")
        XCTAssertEqual(lookalike.imageSearchURL(for: image)?.host(), "lens.google.com", "the image goes to Google's own host, never the template's")
        XCTAssertNil(SearchProvider.google.imageSearchURL(for: URL(string: "data:image/png;base64,AA==")!))
        XCTAssertNil(SearchProvider.google.imageSearchURL(for: URL(string: "file:///tmp/a.gif")!))

        let params = PageContextMenuParams(srcURL: image.absoluteString, mediaType: .image, hasImageContents: true)
        XCTAssertFalse(PageContextMenuPlan.plan(for: params, options: options).items.contains { if case .searchImage = $0 { true } else { false } },
                       "no item when the engine cannot search by image")
    }

    func testSelectionAndEditableMenus() {
        let selection = PageContextMenuParams(selectionText: "  red\npandas  ", editFlags: [.canCopy, .canSelectAll])
        let plan = PageContextMenuPlan.plan(for: selection, options: options)
        XCTAssertEqual(plan.items, [.copy, .searchFor("red\npandas"), .inspect])
        XCTAssertEqual(PageContextMenuItem.searchFor("red\npandas").title, "Search for “red pandas”")
        XCTAssertEqual(PageContextMenuPlan.truncated(String(repeating: "x", count: 40)), String(repeating: "x", count: 30) + "…")

        let editable = PageContextMenuParams(editFlags: [.canPaste, .canSelectAll], isEditable: true)
        let edit = PageContextMenuPlan.plan(for: editable, options: options)
        XCTAssertEqual(edit.items, [.cut, .copy, .paste, .selectAll, .inspect])
        XCTAssertEqual(edit.entry(.cut)?.isEnabled, false)
        XCTAssertEqual(edit.entry(.paste)?.isEnabled, true)
        XCTAssertEqual(edit.entry(.selectAll)?.isEnabled, true)
    }

    func testPageMenu() {
        let plan = PageContextMenuPlan.plan(for: PageContextMenuParams(pageURL: "https://a.test/", editFlags: [.canSelectAll]), options: options)
        XCTAssertEqual(plan.items, [.back, .forward, .reload, .selectAll, .viewSource, .inspect])
        XCTAssertEqual(plan.entry(.back)?.isEnabled, true)
        XCTAssertEqual(plan.entry(.forward)?.isEnabled, false)
    }

    // MARK: Passwords and downloads

    func testPasswordOfferText() {
        let save = PasswordSavePrompt(id: 1, origin: "https://login.example", username: "ana", isUpdate: false)
        XCTAssertEqual(save.title, "Save password for login.example?")
        XCTAssertEqual(save.saveTitle, "Save")
        let update = PasswordSavePrompt(id: 2, origin: "https://login.example", username: "", isUpdate: true)
        XCTAssertEqual(update.title, "Update password for login.example?")
        XCTAssertEqual(update.saveTitle, "Update")
        XCTAssertEqual(update.displayUsername, "No username")
        XCTAssertEqual(PasswordPromptAction.notNow.rawValue, 2)
    }

    func testDownloadsFileFromBeforeWave22DoesNotAsk() throws {
        let old = Data(#"{"version":1,"directory":"/tmp/d","list":{"records":[]}}"#.utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w22-dl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try old.write(to: url)
        let contents = DownloadListFile.load(from: url)
        XCTAssertEqual(contents.directory, "/tmp/d")
        XCTAssertNil(contents.askWhereToSave)
        try DownloadListFile.save(.init(directory: "/tmp/d", askWhereToSave: true), to: url)
        XCTAssertEqual(DownloadListFile.load(from: url).askWhereToSave, true)
    }
}

final class ContextMenuOpenSecurityTests: XCTestCase {
    func testPageSourcedLinksAndImagesOnlyOpenHTTPAndHTTPS() {
        for string in ["data:text/html,test", "file:///tmp/test.html", "javascript:alert(1)",
                       "about:blank", "chrome://settings", "https:missing-host"] {
            let params = PageContextMenuParams(linkURL: string, srcURL: string, mediaType: .image)
            XCTAssertNil(params.openableLink, string)
            XCTAssertNil(params.openableImage, string)
        }
        for string in ["http://example.test/a", "https://example.test/a"] {
            let params = PageContextMenuParams(linkURL: string, srcURL: string, mediaType: .image)
            XCTAssertEqual(params.openableLink?.absoluteString, string)
            XCTAssertEqual(params.openableImage?.absoluteString, string)
        }
    }
}
