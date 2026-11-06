import AppKit
import SwiftUI
import SidebarModel

/// Runs `content` in its own `NSHostingView` (perf-4). A SwiftUI scroll view
/// flushes its whole graph on each bounds change and lays out the root
/// hosting view; in the window's graph that is all of `BrowserView`. In a
/// graph of its own a scroll step renders the list alone, and a change the
/// list observes no longer invalidates the window.
///
/// Environment does not cross a hosting view, so the values the sidebar's
/// rows read are carried over here and set again on the inner root.
struct SidebarListHost<Content: View>: View {
    var tint: Color
    @ViewBuilder let content: () -> Content
    @Environment(\.themeChrome) private var chrome
    @Environment(\.sidebarWindow) private var window
    @Environment(\.spacePager) private var pager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HostedGraph(root: SidebarListRoot(
            chrome: chrome, window: window, pager: pager, colorScheme: colorScheme, tint: tint, content: content()
        ))
    }
}

/// The inner graph's root: the carried environment, then the content.
struct SidebarListRoot<Content: View>: View {
    let chrome: ThemeChromeColors
    let window: SidebarWindowID?
    let pager: SpacePagerController?
    let colorScheme: ColorScheme
    let tint: Color
    let content: Content

    var body: some View {
        content
            .foregroundStyle(chrome.title)
            .tint(tint)
            .environment(\.themeChrome, chrome)
            .environment(\.sidebarWindow, window)
            .environment(\.spacePager, pager)
            .environment(\.colorScheme, colorScheme)
            .ignoresSafeArea()
    }
}

/// An `NSHostingView` for `root`, sized by its SwiftUI parent. It reports no
/// intrinsic size and takes the size it is offered, so the window neither
/// lays out again for it nor measures its views through Auto Layout (the
/// default fitting-size path walked the whole list on every scroll step).
struct HostedGraph<Root: View>: NSViewRepresentable {
    let root: Root

    func makeNSView(context: Context) -> NSHostingView<Root> {
        let view = NSHostingView(rootView: root)
        view.sizingOptions = []
        return view
    }

    func updateNSView(_ view: NSHostingView<Root>, context: Context) {
        view.rootView = root
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<Root>, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
