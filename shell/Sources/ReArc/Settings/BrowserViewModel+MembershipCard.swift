import AppKit
import SidebarModel
import SwiftUI

/// The membership card's file and its moments (SETTINGS.md §12): it is read
/// off the main thread at launch and made on the first one, which sets the
/// ReArc start date once (an existing install starts on the day it updates).
@Observable
final class MembershipCardStore {
    private(set) var card: MembershipCard?
    /// The Arc-to-ReArc transition is playing from this moment.
    private(set) var transitionStart: Date?
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "net.rearc.membership-card", qos: .utility)
    @ObservationIgnored private var transitionToken = UUID()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// At launch: read the file in the background; make the card if there is none.
    func loadInBackground() {
        let url = fileURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = MembershipCardFile.load(from: url)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.card == nil else { return }
                self.adopt(loaded)
            }
        }
    }

    /// The card now, read on the spot if the launch read hasn't landed yet.
    @discardableResult
    func ensureLoaded() -> MembershipCard {
        if let card { return card }
        adopt(MembershipCardFile.load(from: fileURL))
        return card!
    }

    private func adopt(_ loaded: MembershipCard?) {
        if let loaded {
            card = loaded
        } else {
            card = MembershipCard.fresh(now: now())
            save()
        }
    }

    func update(_ change: (inout MembershipCard) -> Void) {
        var card = ensureLoaded()
        change(&card)
        guard card != self.card else { return }
        self.card = card
        save()
    }

    private func save() {
        guard let card else { return }
        let url = fileURL
        saveQueue.async { try? MembershipCardFile.save(card, to: url) }
    }

    /// Plays the transition (from the Account tab's first showing after an
    /// import, or Replay). It counts as shown once it starts.
    func playTransition(reduceMotion: Bool) {
        guard ensureLoaded().hasArcHistory else { return }
        update { $0.transitionShown = true }
        let token = UUID()
        transitionToken = token
        transitionStart = now()
        let duration = reduceMotion ? MembershipCardTransition.reducedDuration : MembershipCardTransition.duration
        if !reduceMotion {
            DispatchQueue.main.asyncAfter(deadline: .now() + MembershipCardTransition.stampContact) { [weak self] in
                guard self?.transitionToken == token else { return }
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
            guard let self, self.transitionToken == token else { return }
            self.transitionStart = nil
        }
    }

    /// The Account tab shows: an imported card tells its story once.
    func accountTabAppeared(reduceMotion: Bool) {
        let card = ensureLoaded()
        if card.hasArcHistory, !card.transitionShown, transitionStart == nil { playTransition(reduceMotion: reduceMotion) }
    }
}

extension BrowserViewModel {
    /// The account's name: the active profile's, as Arc names its tab after the account.
    var accountName: String { store.activeProfile.name }

    /// The name printed on the card.
    var membershipCardName: String {
        membershipCard.ensureLoaded().displayName(profileName: accountName)
    }

    /// Palette 0's colour: the active profile's theme.
    var membershipCardTheme: SpaceColor {
        let theme = store.activeProfile.themeColor
        return SpaceColor(red: theme.red, green: theme.green, blue: theme.blue)
    }

    /// Act 1's name, from the onboarding (a real first run only).
    func recordOnboardingName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        membershipCard.update { $0.name = trimmed }
    }

    /// The account ⋯ menu's Change Name…: the profile and the card take it.
    func changeAccountName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = store.renameProfile(store.activeProfileID, to: trimmed)
        membershipCard.update { $0.name = trimmed }
    }

    func randomizeMembershipCard() {
        membershipCard.update { $0.randomize() }
    }

    /// Arc's card into ReArc's: from File › Import, the onboarding, or the card's own button.
    func importArcMembershipCard(_ imported: ArcMembershipCardImport) {
        membershipCard.update { $0 = imported.applied(to: $0) }
    }

    /// The card offers Import from Arc while it has no Arc story and Arc's files are there.
    func canImportArcMembershipCard(applicationSupport: URL = BrowserImportDiscovery.applicationSupport) -> Bool {
        !membershipCard.ensureLoaded().hasArcHistory && ArcMembershipCardImport.exists(in: applicationSupport)
    }

    /// The card's Import from Arc; false when Arc's files gave nothing.
    @discardableResult
    func importArcMembershipCardFromArc(applicationSupport: URL = BrowserImportDiscovery.applicationSupport) -> Bool {
        guard let imported = ArcMembershipCardImport.load(from: applicationSupport) else { return false }
        importArcMembershipCard(imported)
        return true
    }
}

/// The card as a picture: Share and Download (SETTINGS.md §12.1).
@MainActor
enum MembershipCardExport {
    /// The card at 4× on a backdrop in its palette: 1648 × 2124 px, as Arc's download.
    static func pngData(card: MembershipCard, name: String, theme: SpaceColor) -> Data? {
        let palette = MembershipCardPalette.palette(card.palette, theme: theme)
        let content = ZStack {
            RadialGradient(colors: [Color(palette.colours[1]), Color(palette.colours[3])],
                           center: .center, startRadius: 40, endRadius: 330)
            MembershipCardView(card: card, name: name, theme: theme, isLive: false)
        }
        .frame(width: 412, height: 531)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 4
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func fileName(for name: String) -> String {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return "\(safe.isEmpty ? "ReArc" : safe)_ReArc.png"
    }

    /// A copy in a private temporary folder, for the share picker.
    static func temporaryFile(card: MembershipCard, name: String, theme: SpaceColor) -> URL? {
        guard let data = pngData(card: card, name: name, theme: theme) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReArc-Card", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(for: name))
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }

    /// Download: a Save panel in Downloads, "<Name>_ReArc.png", as Arc's.
    static func download(card: MembershipCard, name: String, theme: SpaceColor, from window: NSWindow?) {
        guard let data = pngData(card: card, name: name, theme: theme) else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName(for: name)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let save = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            if (try? data.write(to: url, options: .atomic)) == nil { NSSound.beep() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: save) } else { save(panel.runModal()) }
    }

    /// Share: the macOS share picker with the picture and a line of text.
    static func share(card: MembershipCard, name: String, theme: SpaceColor, from view: NSView) {
        guard let url = temporaryFile(card: card, name: name, theme: theme) else { return NSSound.beep() }
        NSSharingServicePicker(items: ["I moved to ReArc.", url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

/// Share ReArc with a Friend. The rearc.net invite service is later
/// (SETTINGS.md §13); until then the picker carries the site's address.
enum ShareReArc {
    static let link = URL(string: "https://rearc.net")!
    static let message = "Try ReArc, a calm browser for the Mac:"

    @MainActor static func show(from view: NSView) {
        NSSharingServicePicker(items: [message, link]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}
