import Foundation

/// Side-effect the shell performs when the user picks a command-bar command.
public enum AppCommandAction: Equatable, Hashable {
    case newTab
    case closeTab
    case reopenClosedTab
    case pinTab
    case unpinTab
    case moveTabToSpace(Space.ID)
    case switchToSpace(Space.ID)
    case switchToProfile(Profile.ID)
    /// Change Profile of Current Space (Arc `changeProfileForCurrentSpace`).
    case moveSpaceToProfile(Profile.ID)
    case createProfile
    case renameActiveProfile
    case createSpace
    case toggleSidebar
    case addSplitRight
    case addSplitBottom
    case separateFromSplit
    case nextTab
    case previousTab
    case peekAtURL
    case openLittleArcWindow
    case openInLittleArc
    case promoteLittleArcToTab
    case muteTab
    case unmuteAllTabs
    case pauseAllMedia
    case snoozeAutoPiPForSite
    /// Enter or leave Picture in Picture for the selected tab's video.
    case togglePictureInPicture
    case printPage
    case exportPageAsPDF
    case newBoostForSite
    case manageBoosts
    case toggleBoost(UUID)
    case editBoost(UUID)
    case pickElementToEdit
    case newEasel
    case newNote
    case capturePage
    case captureVisibleArea
    case openCapturesGallery
    case openBrowserPage(BrowserInternalPage)
    case viewPageSource
    case goBack
    case goForward
    case reloadPage
    case reloadIgnoringCache
    case stopLoading
    case copyURL
    case nextSpace
    case previousSpace
    case renameSpace
    case editSpaceTheme
    case deleteSpace
    case newFolder
    case expandAllFolders
    case collapseAllFolders
    case addToFavorites
    case removeFromFavorites
    case renameTab
    case duplicateTab
    case archiveTab
    case viewArchive
    case resetTabToOriginalURL
    case resetPinnedTabsInSpace
    case updatePinnedURL
    case clearUnpinnedTabs
    case findInPage
    case showDownloads
    case clearCommandBarHistory
    /// Arc `setAsDefaultBrowser` (COMMAND-BAR §6.6).
    case setAsDefaultBrowser
    case setExternalLinkDestination(ExternalLinkDestination)
}

/// Read-only command-bar context for enablement and dynamic commands.
public struct CommandBarContext {
    public var store: SidebarStore
    public var isSidebarVisible: Bool
    public var closedTabStack: ClosedTabStack
    /// When a peek overlay is open, URL available for "Open in Little Arc".
    public var peekURL: URL?
    /// Frontmost Little Arc window id for promote command.
    public var focusedLittleArcID: LittleArcWindow.ID?
    public var mediaByTab: [Tab.ID: WebMediaState]
    public var tabMuteModel: TabMediaMuteModel
    /// What the running engine admits beyond the base URL set (Chromium WebUI, view-source).
    public var navigationSchemes: NavigationURLPolicy.EngineSchemes
    /// Where links from other apps open now (its own command is hidden).
    public var externalLinkDestination: ExternalLinkDestination

    public init(
        store: SidebarStore,
        isSidebarVisible: Bool,
        closedTabStack: ClosedTabStack,
        peekURL: URL? = nil,
        focusedLittleArcID: LittleArcWindow.ID? = nil,
        mediaByTab: [Tab.ID: WebMediaState] = [:],
        tabMuteModel: TabMediaMuteModel = TabMediaMuteModel(),
        navigationSchemes: NavigationURLPolicy.EngineSchemes = [],
        externalLinkDestination: ExternalLinkDestination = .littleArc
    ) {
        self.externalLinkDestination = externalLinkDestination
        self.store = store
        self.isSidebarVisible = isSidebarVisible
        self.closedTabStack = closedTabStack
        self.peekURL = peekURL
        self.focusedLittleArcID = focusedLittleArcID
        self.mediaByTab = mediaByTab
        self.tabMuteModel = tabMuteModel
        self.navigationSchemes = navigationSchemes
    }
}

public struct AppCommand: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var keywords: [String]
    public var minQueryLength: Int
    public var action: AppCommandAction

    public init(
        id: String,
        title: String,
        keywords: [String] = [],
        minQueryLength: Int = 0,
        action: AppCommandAction
    ) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.minQueryLength = minQueryLength
        self.action = action
    }

    public func isEnabled(in context: CommandBarContext) -> Bool {
        let store = context.store
        switch action {
        case .newTab:
            return true
        case .closeTab:
            return store.selectedTabID != nil
        case .reopenClosedTab:
            return context.closedTabStack.canReopen
        case .pinTab:
            guard let id = store.selectedTabID else { return false }
            return store.kind(of: id) == .today
        case .unpinTab:
            guard let id = store.selectedTabID else { return false }
            return store.kind(of: id) == .pinned
        case .moveTabToSpace(let spaceID):
            guard let tabID = store.selectedTabID,
                  store.splitContaining(tabID: tabID) == nil,
                  let from = store.spaceContaining(tabID: tabID) else { return false }
            return from != spaceID
        case .switchToSpace(let spaceID):
            return store.activeSpaceID != spaceID
        case .switchToProfile(let profileID):
            return store.activeProfileID != profileID
        case .moveSpaceToProfile(let profileID):
            return store.profileChangeBlocker(forSpace: store.activeSpaceID, to: profileID) == nil
        case .createProfile:
            return true
        case .renameActiveProfile:
            return !store.profiles.isEmpty
        case .createSpace:
            return true
        case .toggleSidebar:
            return true
        case .addSplitRight, .addSplitBottom:
            guard let tab = store.selectedTab else { return false }
            return store.splitContaining(tabID: tab.id) == nil
        case .separateFromSplit:
            guard let tab = store.selectedTab else { return false }
            return store.splitContaining(tabID: tab.id) != nil
        case .nextTab, .previousTab:
            return !store.displayEntries().isEmpty
        case .peekAtURL, .openLittleArcWindow:
            return true
        case .openInLittleArc:
            if context.peekURL != nil { return true }
            return store.selectedTab != nil
        case .promoteLittleArcToTab:
            if context.focusedLittleArcID != nil { return true }
            return !store.littleArcLiveWindows.isEmpty
        case .muteTab:
            return TabMediaMuteModel.shouldEnableMuteTab(
                selectedTabID: store.selectedTabID,
                media: store.selectedTabID.flatMap { context.mediaByTab[$0] }
            )
        case .unmuteAllTabs:
            return TabMediaMuteModel.shouldEnableUnmuteAll(
                mediaByTab: context.mediaByTab,
                muteModel: context.tabMuteModel
            )
        case .pauseAllMedia:
            return TabMediaMuteModel.shouldEnablePauseAll(mediaByTab: context.mediaByTab)
        case .snoozeAutoPiPForSite:
            guard let tab = store.selectedTab else { return false }
            return tab.url.host() != nil
        case .togglePictureInPicture:
            guard let id = store.selectedTabID, let media = context.mediaByTab[id] else { return false }
            return media.canPictureInPicture || media.isPictureInPicture
        case .printPage, .exportPageAsPDF:
            return store.selectedTab != nil
        case .newBoostForSite:
            guard let tab = store.selectedTab else { return false }
            return BoostScopeMatcher.urlIsEligibleForBoosts(tab.url)
        case .manageBoosts:
            return true
        case .toggleBoost, .editBoost, .pickElementToEdit:
            return store.selectedTab != nil
        case .newEasel, .newNote, .openCapturesGallery:
            return true
        case .capturePage, .captureVisibleArea:
            return store.selectedTab != nil
        case .openBrowserPage(let page):
            return page.isAvailable(engine: context.navigationSchemes)
        case .viewPageSource:
            guard let tab = store.selectedTab else { return false }
            return NavigationURLPolicy.viewSourceURL(for: tab.url, engine: context.navigationSchemes) != nil
        case .goBack, .goForward, .reloadPage, .reloadIgnoringCache, .stopLoading, .copyURL,
             .renameTab, .duplicateTab:
            return store.selectedTab != nil
        case .nextSpace, .previousSpace:
            return store.spacesInActiveProfile.count > 1
        case .renameSpace, .editSpaceTheme, .newFolder, .viewArchive:
            return true
        case .deleteSpace:
            return store.spaces.count > 1
        case .expandAllFolders, .collapseAllFolders:
            return !store.folderOutline().isEmpty
        case .addToFavorites, .archiveTab:
            guard let id = store.selectedTabID, store.splitContaining(tabID: id) == nil else { return false }
            return store.kind(of: id) == .pinned || store.kind(of: id) == .today
        case .removeFromFavorites:
            return store.selectedTabID.flatMap { store.kind(of: $0) } == .favorite
        case .resetTabToOriginalURL, .updatePinnedURL:
            return store.selectedTab?.isAwayFromSavedURL == true
        case .resetPinnedTabsInSpace:
            return SidebarTree.tabs(store.content(for: store.activeSpaceID).pinned).contains(where: \.isAwayFromSavedURL)
        case .clearUnpinnedTabs:
            return store.content(for: store.activeSpaceID).todayLeaves.contains {
                if case .tab = $0 { return true }
                return false
            }
        case .findInPage:
            return store.selectedTab != nil
        case .showDownloads, .clearCommandBarHistory, .setAsDefaultBrowser:
            return true
        case .setExternalLinkDestination(let destination):
            return context.externalLinkDestination != destination
        }
    }
}

/// Static catalog plus space-derived commands.
public enum AppCommandRegistry {

    public static func all(in context: CommandBarContext) -> [AppCommand] {
        var commands = staticCommands(in: context)
        for space in context.store.spacesInActiveProfile {
            commands.append(AppCommand(
                id: "switch-space-\(space.id.uuidString)",
                title: "Switch to \(space.name)",
                keywords: ["space", space.name, "switch"],
                minQueryLength: 1,
                action: .switchToSpace(space.id)
            ))
            commands.append(AppCommand(
                id: "move-tab-space-\(space.id.uuidString)",
                title: "Move Tab to \(space.name)",
                keywords: ["move", "tab", space.name, "space"],
                minQueryLength: 2,
                action: .moveTabToSpace(space.id)
            ))
        }
        for profile in context.store.profiles {
            commands.append(AppCommand(
                id: "switch-profile-\(profile.id.uuidString)",
                title: "Switch to \(profile.name)",
                keywords: ["profile", profile.name, "switch", "account"],
                minQueryLength: 1,
                action: .switchToProfile(profile.id)
            ))
            commands.append(AppCommand(
                id: "move-space-profile-\(profile.id.uuidString)",
                title: "Move Space to \(profile.name)",
                keywords: ["change", "profile", profile.name, "space", "move"],
                minQueryLength: 2,
                action: .moveSpaceToProfile(profile.id)
            ))
        }
        for destination in ExternalLinkDestination.allCases {
            commands.append(AppCommand(
                id: "external-links-\(destination.rawValue)",
                title: destination.title,
                keywords: ["external", "links", "default", "browser", "little", "arc", "space", "open"],
                minQueryLength: 3,
                action: .setExternalLinkDestination(destination)
            ))
        }
        if let tab = context.store.selectedTab,
           BoostScopeMatcher.urlIsEligibleForBoosts(tab.url) {
            let matches = context.store.boostsMatchingPage(tab.url)
            for (package, install) in matches {
                let state = install.enabled ? "On" : "Off"
                commands.append(AppCommand(
                    id: "toggle-boost-\(package.manifest.id.uuidString)",
                    title: "Toggle Boost: \(package.manifest.name) (\(state))",
                    keywords: ["boost", "toggle", package.manifest.name, "site", "extension"],
                    minQueryLength: 1,
                    action: .toggleBoost(package.manifest.id)
                ))
                commands.append(AppCommand(
                    id: "edit-boost-\(package.manifest.id.uuidString)",
                    title: "Edit Boost: \(package.manifest.name)",
                    keywords: ["boost", "edit", "editor", package.manifest.name, "css", "pick"],
                    minQueryLength: 1,
                    action: .editBoost(package.manifest.id)
                ))
            }
            commands.append(AppCommand(
                id: "pick-element-boost",
                title: "Pick Element to Edit",
                keywords: ["boost", "pick", "element", "selector", "edit"],
                minQueryLength: 2,
                action: .pickElementToEdit
            ))
        }
        return commands.filter { $0.isEnabled(in: context) }
    }

    private static func staticCommands(in context: CommandBarContext) -> [AppCommand] {
        let sidebarTitle = context.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        return [
            AppCommand(
                id: "new-tab",
                title: "New Tab",
                keywords: ["tab", "open", "create"],
                action: .newTab
            ),
            AppCommand(
                id: "close-tab",
                title: "Close Tab",
                keywords: ["tab", "close", "kill"],
                minQueryLength: 1,
                action: .closeTab
            ),
            AppCommand(
                id: "reopen-closed-tab",
                title: "Reopen Closed Tab",
                keywords: ["reopen", "restore", "undo", "closed"],
                minQueryLength: 1,
                action: .reopenClosedTab
            ),
            AppCommand(
                id: "pin-tab",
                title: "Pin Tab",
                keywords: ["pin", "pinned"],
                minQueryLength: 2,
                action: .pinTab
            ),
            AppCommand(
                id: "unpin-tab",
                title: "Unpin Tab",
                keywords: ["unpin", "pinned"],
                minQueryLength: 2,
                action: .unpinTab
            ),
            AppCommand(
                id: "create-space",
                title: "Create Space",
                keywords: ["space", "new", "create"],
                minQueryLength: 2,
                action: .createSpace
            ),
            AppCommand(
                id: "new-profile",
                title: "New Profile",
                keywords: ["profile", "new", "create", "account"],
                minQueryLength: 2,
                action: .createProfile
            ),
            AppCommand(
                id: "rename-profile",
                title: "Rename Profile…",
                keywords: ["profile", "rename", "name"],
                minQueryLength: 2,
                action: .renameActiveProfile
            ),
            AppCommand(
                id: "toggle-sidebar",
                title: sidebarTitle,
                keywords: ["sidebar", "hide", "show", "toggle"],
                minQueryLength: 2,
                action: .toggleSidebar
            ),
            AppCommand(
                id: "split-right",
                title: "Add Split View Right",
                keywords: ["split", "right", "horizontal", "pane"],
                minQueryLength: 2,
                action: .addSplitRight
            ),
            AppCommand(
                id: "split-bottom",
                title: "Add Split View Bottom",
                keywords: ["split", "bottom", "vertical", "pane"],
                minQueryLength: 2,
                action: .addSplitBottom
            ),
            AppCommand(
                id: "separate-split",
                title: "Separate from Split View",
                keywords: ["split", "separate", "detach", "unsplit"],
                minQueryLength: 2,
                action: .separateFromSplit
            ),
            AppCommand(
                id: "next-tab",
                title: "Next Tab",
                keywords: ["tab", "next", "forward"],
                minQueryLength: 1,
                action: .nextTab
            ),
            AppCommand(
                id: "previous-tab",
                title: "Previous Tab",
                keywords: ["tab", "previous", "back"],
                minQueryLength: 1,
                action: .previousTab
            ),
            AppCommand(
                id: "peek-at-url",
                title: "Peek at URL…",
                keywords: ["peek", "preview", "link", "url"],
                minQueryLength: 2,
                action: .peekAtURL
            ),
            AppCommand(
                id: "open-little-arc",
                title: "Open Little Arc window",
                keywords: ["little", "arc", "browser", "window", "mini"],
                minQueryLength: 2,
                action: .openLittleArcWindow
            ),
            AppCommand(
                id: "open-in-little-arc",
                title: "Open in Little Arc",
                keywords: ["little", "arc", "open", "move"],
                minQueryLength: 2,
                action: .openInLittleArc
            ),
            AppCommand(
                id: "promote-little-arc",
                title: "Promote Little Arc to tab",
                keywords: ["little", "arc", "promote", "tab", "window"],
                minQueryLength: 2,
                action: .promoteLittleArcToTab
            ),
            AppCommand(
                id: "mute-tab",
                title: "Mute Tab",
                keywords: ["mute", "sound", "audio", "speaker", "tab"],
                minQueryLength: 2,
                action: .muteTab
            ),
            AppCommand(
                id: "unmute-all-tabs",
                title: "Unmute All Tabs",
                keywords: ["unmute", "sound", "audio", "all", "tabs"],
                minQueryLength: 2,
                action: .unmuteAllTabs
            ),
            AppCommand(
                id: "pause-all-media",
                title: "Pause All Media",
                keywords: ["pause", "stop", "media", "video", "audio", "all"],
                minQueryLength: 2,
                action: .pauseAllMedia
            ),
            AppCommand(
                id: "snooze-auto-pip",
                title: "Snooze Auto-PiP for This Site (1 hour)",
                keywords: ["pip", "picture", "picture-in-picture", "snooze", "auto", "site"],
                minQueryLength: 2,
                action: .snoozeAutoPiPForSite
            ),
            AppCommand(
                id: "picture-in-picture",
                title: "Picture in Picture",
                keywords: ["pip", "picture-in-picture", "float", "video", "popout", "exit"],
                minQueryLength: 2,
                action: .togglePictureInPicture
            ),
            AppCommand(
                id: "print-page",
                title: "Print…",
                keywords: ["print", "printer", "paper"],
                minQueryLength: 2,
                action: .printPage
            ),
            AppCommand(
                id: "export-pdf",
                title: "Export as PDF…",
                keywords: ["pdf", "save", "export", "print"],
                minQueryLength: 2,
                action: .exportPageAsPDF
            ),
            AppCommand(
                id: "new-boost-site",
                title: "New Boost for This Site",
                keywords: ["boost", "new", "create", "site", "extension", "css"],
                minQueryLength: 2,
                action: .newBoostForSite
            ),
            AppCommand(
                id: "set-default-browser",
                title: "Set as Default Browser",
                keywords: ["default", "browser", "default browser", "links", "set"],
                minQueryLength: 3,
                action: .setAsDefaultBrowser
            ),
            AppCommand(
                id: "manage-boosts",
                title: "View Boosts",
                keywords: ["boost", "boosts", "library", "manage", "extensions"],
                minQueryLength: 2,
                action: .manageBoosts
            ),
            AppCommand(
                id: "new-easel",
                title: "New Easel",
                keywords: ["easel", "canvas", "whiteboard", "new", "create"],
                minQueryLength: 2,
                action: .newEasel
            ),
            AppCommand(
                id: "new-note",
                title: "New Note",
                keywords: ["note", "notes", "text", "new", "create"],
                minQueryLength: 2,
                action: .newNote
            ),
            AppCommand(
                id: "capture-page",
                title: "Capture Page",
                keywords: ["capture", "screenshot", "snapshot", "full", "page"],
                minQueryLength: 2,
                action: .capturePage
            ),
            AppCommand(
                id: "capture-visible",
                title: "Capture Visible Area",
                keywords: ["capture", "screenshot", "visible", "viewport", "snapshot"],
                minQueryLength: 2,
                action: .captureVisibleArea
            ),
            AppCommand(
                id: "open-captures-gallery",
                title: "Open Captures Gallery",
                keywords: ["captures", "screenshots", "gallery", "media", "library"],
                minQueryLength: 2,
                action: .openCapturesGallery
            ),
            AppCommand(
                id: "find-in-page",
                title: "Find on Page",
                keywords: ["find", "search", "page", "text", "match"],
                minQueryLength: 2,
                action: .findInPage
            ),
            AppCommand(
                id: "show-downloads",
                title: "Show Downloads",
                // Not "downloads": with Chromium, Chromium's own Downloads page keeps that exact match.
                keywords: ["tray", "files", "progress", "recent"],
                minQueryLength: 2,
                action: .showDownloads
            ),
            AppCommand(
                id: "clear-command-bar-history",
                title: "Clear Command Bar History",
                keywords: ["clear", "history", "visited", "suggestions", "forget"],
                minQueryLength: 3,
                action: .clearCommandBarHistory
            ),
            AppCommand(
                id: "browser-settings",
                title: "Settings",
                keywords: ["settings", "preferences", "options", "chrome", "browser"],
                minQueryLength: 2,
                action: .openBrowserPage(.settings)
            ),
            AppCommand(
                id: "privacy-settings",
                title: "Privacy and Security Settings",
                keywords: ["privacy", "security", "cookies", "settings"],
                minQueryLength: 2,
                action: .openBrowserPage(.privacy)
            ),
            AppCommand(
                id: "site-settings",
                title: "Site Settings",
                keywords: ["site", "permissions", "camera", "location", "notifications", "settings"],
                minQueryLength: 2,
                action: .openBrowserPage(.siteSettings)
            ),
            AppCommand(
                id: "clear-browsing-data",
                title: "Clear Browsing Data…",
                keywords: ["clear", "history", "cache", "cookies", "browsing", "data"],
                minQueryLength: 2,
                action: .openBrowserPage(.clearBrowsingData)
            ),
            AppCommand(
                id: "engine-version",
                title: "About Chromium Engine",
                keywords: ["version", "about", "chromium", "engine"],
                minQueryLength: 2,
                action: .openBrowserPage(.version)
            ),
            AppCommand(
                id: "browser-history",
                title: "History",
                keywords: ["history", "visited", "chrome", "browsing"],
                minQueryLength: 2,
                action: .openBrowserPage(.history)
            ),
            AppCommand(
                id: "browser-downloads",
                title: "Downloads",
                keywords: ["downloads", "downloaded", "files"],
                minQueryLength: 2,
                action: .openBrowserPage(.downloads)
            ),
            AppCommand(
                id: "browser-passwords",
                title: "Passwords",
                keywords: ["passwords", "password", "manager", "logins", "credentials"],
                minQueryLength: 2,
                action: .openBrowserPage(.passwords)
            ),
            AppCommand(
                id: "browser-extensions",
                title: "Extensions",
                keywords: ["extensions", "extension", "addons", "plugins", "chrome"],
                minQueryLength: 2,
                action: .openBrowserPage(.extensions)
            ),
            AppCommand(
                id: "view-page-source",
                title: "View Page Source",
                keywords: ["source", "view", "html", "developer"],
                minQueryLength: 2,
                action: .viewPageSource
            ),
        ] + sidebarCommands
    }

    /// Wave 17: navigation, spaces, folders, favorites and archive (SIDEBAR-SPEC §6).
    private static let sidebarCommands: [AppCommand] = [
        AppCommand(id: "go-back", title: "Back", keywords: ["back", "previous", "history"], minQueryLength: 2, action: .goBack),
        AppCommand(id: "go-forward", title: "Forward", keywords: ["forward", "next", "history"], minQueryLength: 2, action: .goForward),
        AppCommand(id: "reload-page", title: "Reload Page", keywords: ["reload", "refresh"], minQueryLength: 2, action: .reloadPage),
        AppCommand(
            id: "reload-ignoring-cache",
            title: "Reload Ignoring Cache",
            keywords: ["reload", "hard", "refresh", "cache"],
            minQueryLength: 2,
            action: .reloadIgnoringCache
        ),
        AppCommand(id: "stop-loading", title: "Stop Loading", keywords: ["stop", "cancel", "loading"], minQueryLength: 2, action: .stopLoading),
        AppCommand(id: "copy-url", title: "Copy URL", keywords: ["copy", "url", "link", "address"], minQueryLength: 2, action: .copyURL),
        AppCommand(id: "next-space", title: "Next Space", keywords: ["space", "next", "switch"], minQueryLength: 2, action: .nextSpace),
        AppCommand(
            id: "previous-space",
            title: "Previous Space",
            keywords: ["space", "previous", "switch"],
            minQueryLength: 2,
            action: .previousSpace
        ),
        AppCommand(id: "rename-space", title: "Rename Space…", keywords: ["space", "rename", "name"], minQueryLength: 2, action: .renameSpace),
        AppCommand(
            id: "edit-space-theme",
            title: "Edit Space Theme and Icon…",
            keywords: ["space", "theme", "color", "colour", "icon", "emoji"],
            minQueryLength: 2,
            action: .editSpaceTheme
        ),
        AppCommand(id: "delete-space", title: "Delete Space…", keywords: ["space", "delete", "remove"], minQueryLength: 3, action: .deleteSpace),
        AppCommand(id: "new-folder", title: "New Folder", keywords: ["folder", "new", "group"], minQueryLength: 2, action: .newFolder),
        AppCommand(
            id: "expand-all-folders",
            title: "Expand All Folders",
            keywords: ["folder", "expand", "open"],
            minQueryLength: 2,
            action: .expandAllFolders
        ),
        AppCommand(
            id: "collapse-all-folders",
            title: "Collapse All Folders",
            keywords: ["folder", "collapse", "close"],
            minQueryLength: 2,
            action: .collapseAllFolders
        ),
        AppCommand(
            id: "add-to-favorites",
            title: "Add to Favorites",
            keywords: ["favorite", "favourite", "star", "top"],
            minQueryLength: 2,
            action: .addToFavorites
        ),
        AppCommand(
            id: "remove-from-favorites",
            title: "Remove from Favorites",
            keywords: ["favorite", "favourite", "remove", "unfavorite"],
            minQueryLength: 2,
            action: .removeFromFavorites
        ),
        AppCommand(id: "rename-tab", title: "Rename Tab…", keywords: ["rename", "tab", "title"], minQueryLength: 2, action: .renameTab),
        AppCommand(id: "duplicate-tab", title: "Duplicate Tab", keywords: ["duplicate", "copy", "tab"], minQueryLength: 2, action: .duplicateTab),
        AppCommand(
            id: "archive-tab",
            title: "Archive Tab",
            keywords: ["archive", "exit", "unload", "close"],
            minQueryLength: 2,
            action: .archiveTab
        ),
        AppCommand(
            id: "reset-tab",
            title: "Reset Tab to Original URL",
            keywords: ["reset", "pinned", "original", "url", "back"],
            minQueryLength: 2,
            action: .resetTabToOriginalURL
        ),
        AppCommand(
            id: "reset-pinned-tabs",
            title: "Reset All Tabs in This Space",
            keywords: ["reset", "pinned", "all", "space", "original"],
            minQueryLength: 3,
            action: .resetPinnedTabsInSpace
        ),
        AppCommand(
            id: "update-pinned-url",
            title: "Make This the Pinned URL",
            keywords: ["pinned", "url", "save", "update", "change"],
            minQueryLength: 3,
            action: .updatePinnedURL
        ),
        AppCommand(
            id: "clear-unpinned-tabs",
            title: "Clear Unpinned Tabs",
            keywords: ["clear", "tidy", "today", "unpinned", "archive", "clean"],
            minQueryLength: 2,
            action: .clearUnpinnedTabs
        ),
        AppCommand(
            id: "view-archive",
            title: "View Archive",
            keywords: ["archive", "history", "closed", "restore"],
            minQueryLength: 2,
            action: .viewArchive
        ),
    ]
}
