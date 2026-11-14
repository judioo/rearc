import AppKit
import SidebarModel

/// Engines whose Shift-click Peek can be turned off without dropping
/// `linkPeekHandler`, which automatic Peek (off-site links) also uses.
protocol ShiftClickPeekConfigurable: AnyObject {
    var shiftClickPeekEnabled: Bool { get set }
}

/// One choice in the Profiles pane's Search engine pop-up.
struct SearchEngineChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Reads and sets a profile's default search engine for Settings › Profiles.
/// Chromium's comes from `search_engines` (ABI 1.46, per profile); WebKit's
/// choice is app-wide (`webKitSearchPreference`). Without a source the pane
/// shows Search Settings… only.
protocol SearchEngineSettings: AnyObject {
    func engines(for profileID: Profile.ID) -> [SearchEngineChoice]
    func defaultEngine(for profileID: Profile.ID) -> SearchEngineChoice.ID?
    func setDefaultEngine(_ id: SearchEngineChoice.ID, for profileID: Profile.ID)
    /// False while policy manages the default.
    func isEditable(for profileID: Profile.ID) -> Bool
    /// The profile's engines as command-bar site searches (keyword, name, template).
    func siteSearchEngines(for profileID: Profile.ID) -> [SiteSearchEngine]
}

extension SearchEngineSettings {
    func isEditable(for profileID: Profile.ID) -> Bool { true }
    func siteSearchEngines(for profileID: Profile.ID) -> [SiteSearchEngine] { [] }
}

/// The WebKit path's provider preference, the same for every profile.
final class WebKitSearchEngineSettings: SearchEngineSettings {
    private weak var model: BrowserViewModel?

    init(model: BrowserViewModel) { self.model = model }

    func engines(for profileID: Profile.ID) -> [SearchEngineChoice] {
        SearchProvider.builtIn.map { SearchEngineChoice(id: $0.id, name: $0.name) }
    }

    func defaultEngine(for profileID: Profile.ID) -> SearchEngineChoice.ID? {
        model?.webKitSearchPreference?.providerID
    }

    func setDefaultEngine(_ id: SearchEngineChoice.ID, for profileID: Profile.ID) {
        model?.webKitSearchPreference?.providerID = id
    }
}

/// Settings › Icon: ReArc's icon and its variants, drawn from the mark in
/// `brand/icons/` (generate.py) and exported to `shell/Resources/AppIcons`,
/// which the bundle scripts copy into the app.
///
/// `NSApp.applicationIconImage` changes the running app's Dock tile and
/// window icons; `AppBundleIcon` gives ReArc.app itself the same icon, as
/// Arc does, for Finder, Spotlight and the Dock while ReArc is not running.
///
/// A choice saved by an earlier build that no longer exists (Sextant,
/// Compass…) loads as the standard icon.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case standard, firstLight, daybreak, goldenHour, moonrise
    case neon, flutedGlass, sorbet, sketchbook, prism, graphite

    /// The drawer's two lists.
    enum Group: String, CaseIterable, Identifiable {
        /// The mark at moments of the sunrise: only the sun and sky move.
        case sunsPath
        /// The same mark in other materials.
        case treatments

        var id: String { rawValue }
        var title: String { self == .sunsPath ? "Along the Sun's Path" : "Treatments" }
    }

    static let defaultsKey = "rearc.appIcon"

    var id: String { rawValue }

    var group: Group {
        switch self {
        case .standard, .firstLight, .daybreak, .goldenHour, .moonrise: return .sunsPath
        case .neon, .flutedGlass, .sorbet, .sketchbook, .prism, .graphite: return .treatments
        }
    }

    var title: String {
        switch self {
        case .standard: return "ReArc"
        case .firstLight: return "First Light"
        case .daybreak: return "Daybreak"
        case .goldenHour: return "Golden Hour"
        case .moonrise: return "Moonrise"
        case .neon: return "Neon"
        case .flutedGlass: return "Fluted Glass"
        case .sorbet: return "Sorbet"
        case .sketchbook: return "Sketchbook"
        case .prism: return "Prism"
        case .graphite: return "Graphite"
        }
    }

    /// One line under the name, except on the current icon.
    var caption: String {
        switch self {
        case .standard: return "The sun risen"
        case .firstLight: return "Before dawn"
        case .daybreak: return "Sun at the horizon"
        case .goldenHour: return "Evening light"
        case .moonrise: return "Night"
        case .neon: return "Glass tubes"
        case .flutedGlass: return "Seen through reeded glass"
        case .sorbet: return "Soft, glossy pastels"
        case .sketchbook: return "Crayon on ruled paper"
        case .prism: return "Light split across the arcs"
        case .graphite: return "Quiet, for a calm Dock"
        }
    }

    /// The PNG in AppIcons/; nil for the bundle's own icon.
    var fileName: String? {
        switch self {
        case .standard: return nil
        case .firstLight: return "first-light"
        case .daybreak: return "daybreak"
        case .goldenHour: return "golden-hour"
        case .moonrise: return "moonrise"
        case .neon: return "neon"
        case .flutedGlass: return "fluted-glass"
        case .sorbet: return "sorbet"
        case .sketchbook: return "sketchbook"
        case .prism: return "prism"
        case .graphite: return "graphite"
        }
    }

    var imageURL: URL? {
        fileName.flatMap { Bundle.main.url(forResource: $0, withExtension: "png", subdirectory: "AppIcons") }
    }

    /// A build run outside its bundle has only the standard icon.
    var isAvailable: Bool { fileName == nil || imageURL != nil }

    static var available: [AppIconChoice] { allCases.filter(\.isAvailable) }

    /// The image the Settings row shows.
    var image: NSImage? {
        guard fileName != nil else { return NSImage(named: NSImage.applicationIconName) }
        return imageURL.flatMap(NSImage.init(contentsOf:))
    }

    /// At launch and on change; the standard icon restores the bundle's.
    func apply() {
        let image = fileName == nil ? nil : image
        MainActor.assumeIsolated {
            NSApp?.applicationIconImage = image
            // The engine's download-progress tile draws the app icon in a view of its own.
            NSApp?.dockTile.display()
        }
        AppBundleIcon.shared.apply(self)
    }

    static func load(from defaults: UserDefaults) -> AppIconChoice {
        defaults.string(forKey: defaultsKey).flatMap(AppIconChoice.init(rawValue:)).flatMap { $0.isAvailable ? $0 : nil } ?? .standard
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// ReArc.app's own icon: the custom icon Finder shows for a folder
/// (`NSWorkspace.setIcon`, an `Icon\r` file and the FinderInfo flag in the
/// bundle's root), which Finder, Spotlight, Launchpad and the Dock use for
/// the app while it is not running. The signed contents are untouched.
///
/// Applied on change and at every launch, so a Sparkle update, which
/// replaces the bundle, gets it back. The bundle is written only when it is
/// out of step, off the main thread, and quietly not at all when it is not
/// writable (a root-owned copy). A bundle `scripts/release.sh` is verifying,
/// and a launch on a throwaway `REARC_DATA_DIR`, read the person's choice
/// too, so they leave the bundle alone: the one verified is the one shipped
/// (`REARC_BUNDLE_ICON=1` lets a QA launch write it anyway).
final class AppBundleIcon: @unchecked Sendable {
    static let shared = AppBundleIcon(bundlePath: Bundle.main.bundlePath, writes: defaultWrites())
    static let recordKey = "rearc.appIcon.bundle"
    static let environmentKey = "REARC_BUNDLE_ICON"

    let bundlePath: String
    let writes: Bool
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "rearc.appBundleIcon", qos: .utility)
    /// Writes the icon (nil: removes it); `NSWorkspace.setIcon` but in tests.
    private let setIcon: @Sendable (URL?, String) -> Bool

    init(bundlePath: String, writes: Bool, defaults: UserDefaults = .standard,
         setIcon: @escaping @Sendable (URL?, String) -> Bool = AppBundleIcon.workspaceSetIcon) {
        self.bundlePath = bundlePath
        self.writes = writes && bundlePath.hasSuffix(".app")
        self.defaults = defaults
        self.setIcon = setIcon
    }

    static func defaultWrites(environment: [String: String] = ProcessInfo.processInfo.environment,
                              infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        if environment[environmentKey] == "1" { return true }
        if ShippedBuild.isVerificationBundle(infoDictionary: infoDictionary) { return false }
        return environment[ShellDataLocation.environmentKey]?.isEmpty ?? true
    }

    static func workspaceSetIcon(_ imageURL: URL?, _ path: String) -> Bool {
        guard FileManager.default.isWritableFile(atPath: path) else { return false }
        if let imageURL {
            guard let image = NSImage(contentsOf: imageURL) else { return false }
            return NSWorkspace.shared.setIcon(image, forFile: path, options: [])
        }
        return NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
    }

    /// The `Icon\r` file a custom folder icon keeps in the bundle's root.
    var hasCustomIcon: Bool { FileManager.default.fileExists(atPath: bundlePath + "/Icon\r") }

    /// What `apply` writes: nothing (nil), the choice's image, or `.some(nil)` to remove it.
    func pendingWrite(for choice: AppIconChoice, imageURL: URL?) -> URL?? {
        if choice == .standard || imageURL == nil { return hasCustomIcon ? .some(nil) : nil }
        let written = defaults.string(forKey: Self.recordKey) == choice.rawValue
        return hasCustomIcon && written ? nil : .some(imageURL)
    }

    func apply(_ choice: AppIconChoice) {
        guard writes else { return }
        let imageURL = choice.imageURL
        queue.async { [self] in
            guard let write = pendingWrite(for: choice, imageURL: imageURL) else { return }
            if setIcon(write, bundlePath) {
                defaults.set(write == nil ? nil : choice.rawValue, forKey: Self.recordKey)
            }
        }
    }

    /// Before Sparkle applies a delta, which checks the bundle it patches
    /// file by file: the bundle as shipped. `apply` puts the icon back.
    func removeForUpdate() {
        guard writes else { return }
        queue.sync {
            if hasCustomIcon { _ = setIcon(nil, bundlePath) }
        }
    }

    /// Waits for the writes queued so far (tests).
    func waitForWrites() { queue.sync {} }
}

/// Wave 35: the native Settings window's actions (ARC-RECORDING-2026-11-06 §6.4).
extension BrowserViewModel {
    static let peekOnShiftClickKey = "rearc.peekOnShiftClick"
    static let littleArcOnModifiedClickKey = "rearc.littleArcOnModifiedClick"

    /// Settings… (⌘,), optionally on one pane.
    func showSettings(_ pane: SettingsPane? = nil) {
        if let pane { settingsPane = pane }
        presentSettings?(pane)
    }

    /// The Search engine pop-up's source, when there is one.
    var activeSearchEngineSettings: (any SearchEngineSettings)? {
        if let searchEngineSettings { return searchEngineSettings }
        return webKitSearchPreference == nil ? nil : WebKitSearchEngineSettings(model: self)
    }

    /// The Settings rows that open Chromium's own pages, when the engine admits them.
    func canOpenBrowserPage(_ page: BrowserInternalPage) -> Bool {
        page.isAvailable(engine: engineHost.navigationSchemes)
    }

    /// Advanced › Enable Boosts: Arc's switch is app-wide, ReArc's per profile, so
    /// it reads on only when every profile has them on and sets them all.
    var boostsEnabledInAllProfiles: Bool {
        get { store.profiles.allSatisfy { store.boostLibrary(for: $0.id).masterEnabled } }
        set {
            for profile in store.profiles { store.setBoostMasterEnabled(newValue, profileID: profile.id) }
            syncAllTabBoosts()
        }
    }

    /// Spaces a profile owns, for the Profiles list ("3 Spaces"), its containers' included.
    func spaceCountText(for profileID: Profile.ID) -> String {
        let count = store.spaces(listedIn: profileID).count
        return count == 1 ? "1 Space" : "\(count) Spaces"
    }

    /// Settings › Links › Archive Little Arcs after: run with the tab
    /// auto-archive. The key window stays; an archived window closes.
    func runLittleArcAutoArchive(now: Date = Date()) {
        let keep = Set([keyLittleArcID].compactMap { $0 })
        let archived = store.autoArchiveIdleLittleArcWindows(referenceDate: now, threshold: littleArcArchiveAfter.interval, keeping: keep)
        for id in archived {
            let profileID = store.littleArcArchivedWindows.last(where: { $0.id == id })?.window.profileID ?? store.activeProfileID
            engineHost.removeLittleArc(id, profileID: profileID)
            if focusedLittleArcID == id { focusedLittleArcID = nil }
            windowPresenter?.dismissLittleArcWindow(id)
        }
    }

    /// ⌘Q with Warn before quitting on: asks first while browser windows are open.
    @MainActor
    func confirmQuit(browserWindows: Int) -> Bool {
        guard QuitWarning.shouldAsk(enabled: warnBeforeQuitting, browserWindows: browserWindows) else { return true }
        let alert = NSAlert()
        alert.messageText = QuitWarning.title
        alert.informativeText = QuitWarning.message(browserWindows: browserWindows)
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let quit = alert.runModal() == .alertFirstButtonReturn
        if quit, alert.suppressionButton?.state == .on { warnBeforeQuitting = false }
        return quit
    }
}
