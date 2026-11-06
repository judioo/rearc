import AppKit
import SidebarModel

/// Window ▸ Show All / Close All Little Arcs and the Dock menu (P3.22).
extension BrowserViewModel {
    /// Brings every open Little Arc forward, reopening any whose window is gone.
    func showAllLittleArcs() {
        for record in store.littleArcLiveWindows { requestLittleArcWindow(record.id) }
    }

    /// Closes (archives) every Little Arc; their windows follow their records.
    func closeAllLittleArcs() {
        for record in store.littleArcLiveWindows {
            closeLittleArcWindow(record.id)
            windowPresenter?.dismissLittleArcWindow(record.id)
        }
    }

    /// `newWindow` is nil where the shell cannot open a browser window itself.
    func dockMenu(newWindow: (() -> Void)?) -> NSMenu {
        let menu = NSMenu()
        for entry in LittleArcDockMenu.entries(for: store.littleArcLiveWindows, canOpenBrowserWindow: newWindow != nil) {
            switch entry {
            case .littleArc(let id, let title):
                menu.addItem(ClosureMenuItem(title) { [weak self] in
                    NSApp.activate(ignoringOtherApps: true)
                    self?.requestLittleArcWindow(id)
                })
            case .separator:
                menu.addItem(.separator())
            case .newLittleArc:
                menu.addItem(ClosureMenuItem("New Little Arc Window") { [weak self] in
                    NSApp.activate(ignoringOtherApps: true)
                    self?.openBlankLittleArc()
                })
            case .newWindow:
                menu.addItem(ClosureMenuItem("New Window") {
                    NSApp.activate(ignoringOtherApps: true)
                    newWindow?()
                })
            }
        }
        return menu
    }
}

/// A menu item that runs a closure: the Dock menu is rebuilt on every
/// request, so it keeps no table of actions.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}

/// The WebKit path's Dock menu, through SwiftUI's delegate adaptor.
final class WebKitAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: BrowserViewModel?
    private var onboarding: FirstRunOnboarding?
    private var checkedFirstRun = false

    /// The first window appeared: on a first run, the sunrise takes over.
    @MainActor
    func startOnboardingIfNeeded() {
        guard !checkedFirstRun, let model else { return }
        checkedFirstRun = true
        if let kind = FirstRunOnboarding.kind(isFirstRun: model.isFirstRun) { run(kind) }
    }

    @MainActor
    func watchSunriseAgain() { run(.replay) }

    @MainActor
    private func run(_ kind: FirstRunOnboarding.Kind) {
        guard let model, onboarding == nil else { return }
        let onboarding = FirstRunOnboarding(kind: kind, model: model) {
            NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
        }
        self.onboarding = onboarding
        // After the window is on screen, so it can be put away.
        DispatchQueue.main.async { onboarding.start { [weak self] in self?.onboarding = nil } }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        model?.dockMenu(newWindow: nil)
    }
}

/// The Chromium path's app delegate is the engine's `ReArcAppDelegate`,
/// which has no Dock menu. This adds `applicationDockMenu:` to its class,
/// only if it has none, so a later engine hook takes precedence.
enum ApplicationDockMenuHook {
    private static var provider: (() -> NSMenu?)?

    static func install(_ provider: @escaping () -> NSMenu?) {
        self.provider = provider
        guard let delegate = NSApp.delegate else { return }
        let cls: AnyClass = type(of: delegate)
        let selector = #selector(NSApplicationDelegate.applicationDockMenu(_:))
        guard !class_respondsToSelector(cls, selector) else { return }
        let block: @convention(block) (AnyObject, NSApplication) -> NSMenu? = { _, _ in ApplicationDockMenuHook.provider?() }
        class_addMethod(cls, selector, imp_implementationWithBlock(block), "@@:@")
        // NSApplication may cache what its delegate answers when it is set.
        NSApp.delegate = nil
        NSApp.delegate = delegate
    }
}
