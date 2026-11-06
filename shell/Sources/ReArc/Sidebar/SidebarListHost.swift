import AppKit
import SwiftUI
import SidebarModel

/// Scrolls `content` in an AppKit scroll view, in its own `NSHostingView`
/// (perf-4). A SwiftUI scroll view flushes its graph, places its lazy rows
/// and walks every focus responder on each bounds change, and in the
/// window's graph it also laid out all of `BrowserView`. Here a scroll step
/// moves the clip view and nothing else; a change the list observes updates
/// the list's graph alone.
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
        ScrollingHostedGraph(root: SidebarListRoot(
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

/// An `NSScrollView` whose document is an `NSHostingView` for `root`: full
/// width, as tall as its content. It fills what its SwiftUI parent offers,
/// so the window never measures the list's views through Auto Layout.
struct ScrollingHostedGraph<Root: View>: NSViewRepresentable {
    let root: Root

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.drawsBackground = false

        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            host.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? NSHostingView<Root>)?.rootView = root
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
