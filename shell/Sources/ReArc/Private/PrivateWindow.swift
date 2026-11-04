import SidebarModel
import SwiftUI

/// One private window: a single page whose storage is off the record. On
/// Chromium every window of a private session shares one off-the-record
/// profile under the persistent profile it was opened from, erased when the
/// session's last window closes; on WebKit the engine uses a non-persistent
/// data store. Nothing reaches the sidebar, history or sync.
@Observable
final class PrivateWindowModel: Identifiable {
    let id: UUID
    /// Popups opened from a private window join its session (and storage).
    let session: UUID
    let parentProfileID: Profile.ID
    @ObservationIgnored let engine: any WebEngine
    /// The NSWindow showing this page (set by `PrivateWindowView`).
    @ObservationIgnored weak var hostWindow: NSWindow?
    var addressText = ""
    var addressError: String?

    init(id: UUID = UUID(), session: UUID, parentProfileID: Profile.ID, engine: any WebEngine) {
        self.id = id
        self.session = session
        self.parentProfileID = parentProfileID
        self.engine = engine
    }

    var title: String {
        if let title = engine.pageTitle, !title.isEmpty { return title }
        return engine.currentURL?.host() ?? "Private Window"
    }

    /// `provider` is the parent profile's default search; nothing typed here is sent for suggestions.
    func submitAddress(schemes: NavigationURLPolicy.EngineSchemes, provider: SearchProvider = .duckDuckGo) {
        guard let url = URLEntry.resolve(addressText, engine: schemes, provider: provider) else {
            addressError = "Enter a valid URL or search"
            return
        }
        addressError = nil
        engine.load(url)
    }
}

extension BrowserViewModel {
    /// Opens a private window. `session` nil starts a new private session;
    /// `engine` adopts contents the engine already created (a popup).
    @discardableResult
    func openPrivateWindow(
        session: UUID? = nil,
        parentProfileID: Profile.ID? = nil,
        engine: (any WebEngine)? = nil,
        url: URL? = nil
    ) -> PrivateWindowModel {
        let session = session ?? UUID()
        let parent = parentProfileID ?? store.activeProfileID
        let id = UUID()
        let adopted = engine
        let engine = engine ?? engineHost.privateEngine(session: session, parentProfileID: parent, shellID: id)
        if let adopted { engineHost.configurePrompts(of: adopted, role: .privateWindow, profileID: parent, privateSession: session) }
        let window = PrivateWindowModel(id: id, session: session, parentProfileID: parent, engine: engine)
        engine.linkPeekHandler = nil
        if let url { engine.load(url) }
        privateWindows[id] = window
        if let windowPresenter {
            windowPresenter.presentPrivateWindow(window)
        } else {
            privateWindowOpenRequests.append(id)
        }
        return window
    }

    /// Forgets a closed private window. When it was the last window of its
    /// session, `onPrivateSessionEnded` receives it to release the session's
    /// storage (WebKit's non-persistent store goes with the engine).
    func privateWindowClosed(_ id: UUID) {
        guard let window = privateWindows.removeValue(forKey: id) else { return }
        if !privateWindows.values.contains(where: { $0.session == window.session }) {
            sitePermissions.dropScope(SitePermissionStore.ephemeralPrefix + window.session.uuidString)
            onPrivateSessionEnded?(window)
        }
    }

    /// The private window that is the key window, if any.
    var keyPrivateWindow: PrivateWindowModel? {
        guard let key = NSApp.keyWindow else { return nil }
        return privateWindows.values.first { $0.hostWindow === key }
    }

    /// Cmd+W: a private window shows one page, so it closes the window.
    func closeSelectedTabOrPrivateWindow() {
        if let window = keyPrivateWindow?.hostWindow {
            window.performClose(nil)
        } else {
            closeSelectedTab()
        }
    }

    func clearPrivateWindowOpenRequests() {
        privateWindowOpenRequests = []
    }
}

/// Slim private window: navigation controls, an address field and the page.
struct PrivateWindowView: View {
    @Bindable var model: BrowserViewModel
    let window: PrivateWindowModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            window.engine.makeView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .findBar(model.findBar, for: window.engine)
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Color.purple.opacity(0.08))
        .background(PrivateWindowReader(window: window))
        .navigationTitle(window.title)
        .onAppear { window.addressText = window.engine.currentURL?.absoluteString ?? "" }
        .onChange(of: window.engine.currentURL) { _, url in
            window.addressText = url?.absoluteString ?? ""
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Private", systemImage: "eyeglasses")
                .labelStyle(.iconOnly)
                .foregroundStyle(.purple)
                .help("Private window: cookies and site data are discarded when it closes")
            Button { window.engine.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!window.engine.canGoBack)
            Button { window.engine.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!window.engine.canGoForward)
            Button { window.engine.reload() } label: { Image(systemName: "arrow.clockwise") }
            TextField("Search or enter address", text: Bindable(window).addressText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    window.submitAddress(
                        schemes: model.engineHost.navigationSchemes,
                        provider: model.commandBarServices.searchProvider(for: window.parentProfileID)
                    )
                }
            if let error = window.addressError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !PageZoom.isDefault(window.engine.zoomFactor) {
                Button("\(PageZoom.percent(window.engine.zoomFactor))%") { window.engine.setZoomFactor(1.0) }
                    .font(.caption.monospacedDigit())
                    .help("Page zoom — click to reset to 100% (⌘0)")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Records the NSWindow hosting a private window, for key-window commands
/// (zoom, Cmd+W) on both the WebKit scene and the Chromium shell window.
private struct PrivateWindowReader: NSViewRepresentable {
    let window: PrivateWindowModel

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onWindow = { [weak window] in window?.hostWindow = $0 }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// A restored private-window scene whose session is gone: close it.
struct ClosedPrivateWindowView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear { dismiss() }
    }
}
