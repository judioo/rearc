import AppKit
import SwiftUI
import SidebarModel

/// The row's site icon while its page loads: a ring that fills with the
/// load progress (Arc `ARC_GlowProgressLoadingIndicator`), or a warning
/// glyph when the page crashed.
struct TabActivityIcon<Icon: View>: View {
    let activity: TabActivity
    @ViewBuilder let icon: () -> Icon
    @State private var spin = false

    var body: some View {
        switch activity {
        case .idle:
            icon()
        case .loading(let progress):
            icon()
                .opacity(0.55)
                .overlay {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1.6)
                        Circle()
                            .trim(from: 0, to: max(progress ?? 0.25, 0.12))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .rotationEffect(.degrees(spin ? 270 : -90))
                    }
                    .frame(width: 18, height: 18)
                }
                .onAppear {
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
                }
                .onDisappear { spin = false }
                .help("Loading…")
                .accessibilityLabel("Loading")
        case .crashed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .help("This page crashed — open it to reload")
                .accessibilityLabel("Page crashed")
        }
    }
}

extension View {
    /// The page's load bar along its top edge and, when its renderer is
    /// gone, the crashed-page placeholder with Reload over it.
    func pageStatus(_ activity: TabActivity, onReload: @escaping () -> Void) -> some View {
        overlay(alignment: .top) { PageLoadBar(activity: activity) }
            .overlay {
                if activity == .crashed {
                    CrashedPageView(onReload: onReload)
                        .transition(.opacity)
                }
            }
    }

    /// A transient confirmation just inside the card's top-right corner,
    /// over the toolbar strip (ARC-RECORDING-ANALYSIS.md §6), or centred
    /// `toolbarHeight` down, under the strip, covering no control.
    func shellToast(_ toast: ShellToast?, toolbarHeight: CGFloat = 0, openSettings: @escaping (SettingsPane) -> Void = { _ in },
                    undo: @escaping () -> Void = {}, choose: @escaping (Bool) -> Void = { _ in }) -> some View {
        overlay(alignment: .topTrailing) {
            if let toast, toast.placement == .corner {
                ShellToastView(toast: toast, choose: choose, openSettings: openSettings, undo: undo)
                    .padding(.top, 5)
                    .padding(.trailing, 6)
                    .transition(.scale(scale: 0.5, anchor: .topTrailing).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .overlay(alignment: .top) {
            if let toast, toast.placement == .belowToolbar {
                ShellToastView(toast: toast, choose: choose, openSettings: openSettings, undo: undo)
                    .padding(.top, toolbarHeight + 8)
                    .transition(.scale(scale: 0.5, anchor: .top).combined(with: .opacity))
                    .id(toast.id)
            }
        }
    }
}

extension ShellToast {
    /// In over one or two 10 fps frames from ≈ 50 % scale; out in one.
    static let inAnimation = Animation.easeOut(duration: 0.15)
    static let outAnimation = Animation.easeIn(duration: 0.1)
}

/// The toast itself: a rounded rectangle tinted by the space's theme, with
/// a thin border and a soft shadow; keycaps as chips, then the action.
struct ShellToastView: View {
    let toast: ShellToast
    /// Opens import details (true) or dismisses the toast (false).
    var choose: (Bool) -> Void = { _ in }
    /// A tip's "Settings…" button.
    var openSettings: (SettingsPane) -> Void = { _ in }
    /// The Undo button.
    var undo: () -> Void = {}
    @Environment(\.themeChrome) private var chrome
    @State private var shareAnchor: NSView?

    var body: some View {
        HStack(spacing: 8) {
            if !toast.systemImage.isEmpty {
                Image(systemName: toast.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(chrome.accent)
            }
            HStack(spacing: 3) {
                ForEach(Array(toast.segments.enumerated()), id: \.offset) { _, segment in
                    if segment.isKeycap {
                        Text(segment.text)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(chrome.title.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(chrome.title.opacity(0.2)))
                    } else {
                        Text(segment.text)
                    }
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(chrome.title)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(toast.message)
            if case .share(let url) = toast.action {
                Button {
                    if let shareAnchor { ToastSharePicker.show(url, under: shareAnchor) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 20)
                        .background(chrome.title.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .background(AnchorReader { anchor in
                    shareAnchor = anchor
                    ToastSharePicker.anchor = anchor
                })
                .foregroundStyle(chrome.title)
                .help("Share")
                .accessibilityLabel("Share copied link")
            }
            if toast.action == .reinstallExtensions {
                toastButton("Details", prominent: true) { choose(true) }
            }
            if case .openSettings(let pane) = toast.action {
                toastButton("Settings…", prominent: true) { openSettings(pane) }
            }
            if toast.action == .undo {
                toastButton("Undo", prominent: true, action: undo)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, toast.action == nil ? 12 : 6)
        .frame(height: 30)
        .background(chrome.toast, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(chrome.title.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
    }

    private func toastButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(chrome.title.opacity(prominent ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(chrome.title)
    }
}

/// The toast's share menu: AppKit's picker under the button. ShareLink's
/// picker runs in a view service, so nothing in the app could see it open.
enum ToastSharePicker {
    /// Times the picker was shown (the self-test checks this).
    @MainActor static private(set) var shownCount = 0
    /// The share button's view, so the self-test can click where it is.
    @MainActor static weak var anchor: NSView?

    @MainActor static func show(_ url: URL, under anchor: NSView) {
        // Counted first: an AppKit menu picker tracks inside `show`.
        shownCount += 1
        NSSharingServicePicker(items: [url]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
}

/// A thin accent bar that follows load progress, then fills and fades.
private struct PageLoadBar: View {
    let activity: TabActivity
    @State private var shownFraction: Double = 0
    @State private var isVisible = false

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.accentColor)
                .shadow(color: Color.accentColor.opacity(0.7), radius: 3)
                .frame(width: proxy.size.width * shownFraction, height: 2.5)
                .opacity(isVisible ? 1 : 0)
        }
        .frame(height: 3)
        .allowsHitTesting(false)
        .onAppear { update(activity.barFraction, animated: false) }
        .onChange(of: activity.barFraction) { _, fraction in update(fraction, animated: true) }
    }

    private func update(_ fraction: Double?, animated: Bool) {
        if let fraction {
            if !isVisible { shownFraction = 0 }
            isVisible = true
            withAnimation(animated ? .easeOut(duration: 0.25) : nil) { shownFraction = fraction }
        } else if isVisible {
            withAnimation(.easeOut(duration: 0.2)) { shownFraction = 1 }
            withAnimation(.easeIn(duration: 0.3).delay(0.2)) { isVisible = false }
        }
    }
}

/// Arc's sad tab (`ARC_SadTab`): the renderer is gone, the tab stays.
struct CrashedPageView: View {
    let onReload: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("This page crashed")
                .font(.title2.weight(.semibold))
            Text("Something went wrong while showing it. Your tab is still here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Reload", action: onReload)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
