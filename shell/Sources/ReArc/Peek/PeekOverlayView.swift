import AppKit
import SwiftUI
import SidebarModel

/// Arc's Peek over the window (`PeekLayout`): a tall borderless card with a
/// slim address line and the page, three round buttons floating at its
/// top-right, and any click outside it closing it. The card grows out of the
/// click and its page appears once it is full size, as in Arc; Reduce Motion
/// fades it in instead. The window's page card is washed out behind it
/// (`PeekBackdropWash`).
struct PeekOverlayView: View {
    let model: BrowserViewModel
    let session: BrowserViewModel.PeekSession
    let layout: PeekLayout
    let bounds: CGRect
    let accent: Color
    @Environment(\.themeChrome) private var chrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false
    @State private var showsPage = false

    var body: some View {
        let fullscreen = layout.isFullscreen
        let rect = grown || reduceMotion || fullscreen
            ? layout.card
            : PeekMotion.originRect(pointer: session.origin, card: layout.card, bounds: bounds)
        let surface = PeekSurface(chrome: chrome)
        ZStack(alignment: .topLeading) {
            // Everything outside the card. The app's mouse-down monitor closes
            // the Peek first and takes the click (`handlePeekMouse`); this tap
            // is the fallback, and a close on a closed Peek does nothing.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 1, coordinateSpace: .local) { point in
                    model.performPeekAction(PeekDismissal.action(for: .click(point), layout: layout))
                }
                .allowsHitTesting(!fullscreen)
                .accessibilityHidden(true)

            if let grabber = layout.grabber {
                Capsule()
                    .fill(chrome.secondaryText.opacity(0.8))
                    .frame(width: grabber.width, height: grabber.height)
                    .position(x: grabber.midX, y: grabber.midY)
                    .opacity(grown || fullscreen ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            card(surface: surface)
                .frame(width: max(0, rect.width), height: max(0, rect.height))
                .position(x: rect.midX, y: rect.midY)

            if !fullscreen {
                ForEach(PeekLayout.Control.allCases, id: \.self) { control in
                    if let frame = layout.frame(of: control) {
                        PeekControlButton(control: control, enabled: control != .split || model.peekSplitAnchor != nil,
                                          accent: accent, surface: surface) {
                            model.performPeekAction(PeekDismissal.action(for: .button(control), layout: layout))
                        }
                        .contextMenu { PeekMoreMenu(model: model) }
                        .position(x: frame.midX, y: frame.midY)
                        .opacity(grown ? 1 : 0)
                    }
                }
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .opacity(reduceMotion && !grown ? 0 : 1)
        // The window the click monitor closes this Peek from (the key window
        // at open can be none when the app is not active).
        .background(AnchorReader { [session] view in
            if let window = view.window, model.peekSession?.engineID == session.engineID { model.peekHostWindow = window }
        })
        .onAppear(perform: appear)
    }

    @ViewBuilder
    private func card(surface: PeekSurface) -> some View {
        let fullscreen = layout.isFullscreen
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: fullscreen ? 0 : PeekLayout.topCornerRadius,
            bottomLeadingRadius: fullscreen ? 0 : PeekLayout.bottomCornerRadius,
            bottomTrailingRadius: fullscreen ? 0 : PeekLayout.bottomCornerRadius,
            topTrailingRadius: fullscreen ? 0 : PeekLayout.topCornerRadius,
            style: .continuous
        )
        VStack(spacing: 0) {
            if showsPage, !fullscreen {
                PeekAddressLine(model: model, engine: model.peekEngine, url: session.url, surface: surface)
            }
            // The page stays in one place in the tree: moving it would detach
            // it, which ends its fullscreen.
            if showsPage, let web = model.peekEngineView() {
                web.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .background(surface.fill)
        .clipShape(shape)
        .overlay { if !fullscreen { shape.strokeBorder(surface.hairline, lineWidth: 1).allowsHitTesting(false) } }
        .background {
            if !fullscreen {
                shape.fill(surface.fill).shadow(color: .black.opacity(surface.isDark ? 0.4 : 0.16), radius: 8, y: 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Peek")
    }

    private func appear() {
        guard !grown else { return }
        let duration = reduceMotion ? PeekMotion.fadeDuration : PeekMotion.openDuration
        withAnimation(reduceMotion ? .easeOut(duration: duration) : .timingCurve(0.23, 1, 0.32, 1, duration: duration)) {
            grown = true
        }
        // Arc's card is blank while it grows; the page fills it once it is full size.
        if reduceMotion || layout.isFullscreen {
            showsPage = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { showsPage = true }
        }
    }
}

/// A closed Peek's card shrinking back into the click it came from (a fade
/// under Reduce Motion), while the page behind comes back.
struct PeekClosingCard: View {
    let closing: BrowserViewModel.PeekClosing
    let layout: PeekLayout
    let bounds: CGRect
    @Environment(\.themeChrome) private var chrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shrunk = false

    var body: some View {
        let surface = PeekSurface(chrome: chrome)
        let rect = shrunk && !reduceMotion
            ? PeekMotion.originRect(pointer: closing.origin, card: layout.card, bounds: bounds)
            : layout.card
        UnevenRoundedRectangle(topLeadingRadius: PeekLayout.topCornerRadius, bottomLeadingRadius: PeekLayout.bottomCornerRadius,
                               bottomTrailingRadius: PeekLayout.bottomCornerRadius, topTrailingRadius: PeekLayout.topCornerRadius,
                               style: .continuous)
            .fill(surface.fill)
            .shadow(color: .black.opacity(surface.isDark ? 0.4 : 0.16), radius: 8, y: 2)
            .frame(width: max(0, rect.width), height: max(0, rect.height))
            .position(x: rect.midX, y: rect.midY)
            .opacity(shrunk ? 0 : 1)
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                let animation: Animation = reduceMotion
                    ? .easeOut(duration: PeekMotion.fadeDuration)
                    : .timingCurve(0.3, 0, 0.2, 1, duration: PeekMotion.closeDuration)
                withAnimation(animation) { shrunk = true }
            }
    }
}

/// The page card behind an open Peek, washed with the window's own
/// background (Arc: about 72 %), so the page reads as set aside, not blacked out.
struct PeekBackdropWash<Background: View>: View {
    let isShown: Bool
    @ViewBuilder let background: () -> Background
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isShown {
                background()
                    .opacity(PeekLayout.backdropWash)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: PeekMotion.fadeDuration)
                   : .timingCurve(0.3, 0, 0.2, 1, duration: isShown ? PeekMotion.openDuration : PeekMotion.closeDuration),
                   value: isShown)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The card's own surface: near-white in light, a dark grey in dark, by the
/// same rule as the card toolbar's ink so its glyphs read on it.
struct PeekSurface {
    let isDark: Bool

    init(chrome: ThemeChromeColors) {
        isDark = CardToolbarInk(chrome: chrome, tint: nil).isDark
    }

    var fill: Color { isDark ? Color(white: 0.14) : Color(white: 0.992) }
    var hairline: Color { isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.14) }
    var button: Color { isDark ? Color(white: 0.2) : .white }
}

/// One of the three round buttons outside the card's top-right.
private struct PeekControlButton: View {
    let control: PeekLayout.Control
    let enabled: Bool
    let accent: Color
    let surface: PeekSurface
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? accent : Color.secondary.opacity(0.5))
                .frame(width: PeekLayout.buttonDiameter, height: PeekLayout.buttonDiameter)
                .background(Circle().fill(surface.button))
                .overlay(Circle().fill(Color.primary.opacity(hovered && enabled ? 0.06 : 0)))
                .shadow(color: .black.opacity(surface.isDark ? 0.35 : 0.14), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(label)
    }

    private var symbol: String {
        switch control {
        case .close: return "xmark"
        case .expand: return "arrow.up.left.and.arrow.down.right"
        case .split: return "rectangle.split.2x1"
        }
    }

    private var label: String {
        switch control {
        case .close: return "Close Peek"
        case .expand: return "Open as Tab"
        case .split: return "Open in Split View"
        }
    }

    private var help: String {
        switch control {
        case .close: return "Close (Esc)"
        case .expand: return "Open as Tab (⌘O)"
        case .split: return enabled ? "Open in Split View" : "Split View needs a tab to split with"
        }
    }
}

/// The rest of what the old header offered, on the buttons' and the address line's menus.
private struct PeekMoreMenu: View {
    let model: BrowserViewModel

    var body: some View {
        Button("Open as Tab") { model.performPeekAction(.expandToTab) }
        Button("Open in Split View") { model.performPeekAction(.openInSplitView) }
            .disabled(model.peekSplitAnchor == nil)
        Button("Open in Little ReArc") { model.peekOpenInLittleArc() }
        Divider()
        Button("Copy Link") { model.peekCopyLink() }
        Divider()
        Button("Close Peek") { model.performPeekAction(.close) }
    }
}

/// The card's top line: back, forward, reload, then the page's real host
/// with its connection state and the rest of its address. It cannot be
/// edited: it is there so the site's origin is always in view.
private struct PeekAddressLine: View {
    let model: BrowserViewModel
    let engine: (any WebEngine)?
    let url: URL
    let surface: PeekSurface

    var body: some View {
        let shown = engine?.currentURL ?? url
        HStack(spacing: 0) {
            CardToolbarButton(symbol: "arrow.left", help: "Back", enabled: engine?.canGoBack == true, width: 30) { engine?.goBack() }
            CardToolbarButton(symbol: "arrow.right", help: "Forward", enabled: engine?.canGoForward == true, width: 30) { engine?.goForward() }
            if engine?.isLoading == true {
                CardToolbarButton(symbol: "xmark", help: "Stop Loading", width: 30) { engine?.stopLoading() }
            } else {
                CardToolbarButton(symbol: "arrow.clockwise", help: "Reload", enabled: engine != nil, width: 30) { engine?.reload() }
            }
            PeekSecurityIcon(state: engine?.securityState ?? .unknown)
                .frame(width: 22)
                .padding(.leading, 4)
            address(shown)
                .padding(.leading, 4)
                .padding(.trailing, 12)
            Spacer(minLength: 0)
        }
        .frame(height: PeekLayout.addressLineHeight)
        .frame(maxWidth: .infinity)
        .background(surface.fill)
        .contentShape(Rectangle())
        .contextMenu { PeekMoreMenu(model: model) }
        .help(shown.absoluteString)
    }

    /// The host in full and first, in the primary ink; the rest of the address after it, quieter, cut at the end.
    private func address(_ url: URL) -> some View {
        let parts = PeekAddress.parts(of: url)
        return (Text(parts.host).foregroundColor(.primary).fontWeight(.medium)
                + Text(parts.rest).foregroundColor(.secondary))
            .font(.system(size: 12.5))
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel("Address, \(url.absoluteString)")
    }
}

/// The Peek's address as it is shown: its real host (an address the page
/// controls can never come first), then the path and query.
enum PeekAddress {
    static func parts(of url: URL) -> (host: String, rest: String) {
        guard let host = url.host(), !host.isEmpty else { return (url.absoluteString, "") }
        let port = url.port.map { ":\($0)" } ?? ""
        let scheme = url.scheme?.lowercased() == "https" ? "" : "\(url.scheme ?? "")://"
        var rest = url.path(percentEncoded: false)
        if rest == "/" { rest = "" }
        if let query = url.query(percentEncoded: false), !query.isEmpty { rest += "?" + query }
        return (PageOrigin.shortenedHost(scheme + host + port, limit: 64), rest)
    }
}

/// The connection state ahead of the host, as the sidebar's URL field shows it.
private struct PeekSecurityIcon: View {
    let state: WebSecurityState

    var body: some View {
        switch state {
        case .secure:
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .help("Connection is secure")
                .accessibilityLabel("Secure connection")
        case .insecure:
            Image(systemName: "lock.open.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
                .help("Connection is not secure")
                .accessibilityLabel("Connection is not secure")
        case .dangerous:
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                .help("Dangerous site")
                .accessibilityLabel("Dangerous site")
        case .none, .unknown:
            Image(systemName: "globe")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}
