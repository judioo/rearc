import AppKit
import SwiftUI
import SidebarModel
import UniformTypeIdentifiers

/// The slot between the media stack and the bottom bar for Arc's "New Arc
/// Version Available" pill (ARC-RECORDING-2026-11-06.md §2 rule 6;
/// UPDATE-NOTICE.md). Empty while `BrowserViewModel.availableUpdate` is nil.
struct UpdateBannerSlot: View {
    let update: AvailableUpdate?
    let install: () -> Void

    var body: some View {
        if let update {
            UpdateNoticePill(update: update, install: install)
        }
    }
}

/// The Library button's downloads quick view (§5.1): the latest downloads
/// rising out of the button, newest at the bottom, straight on the sidebar
/// with no card. Click a row to open the file, drag it out to drag the file.
struct RecentDownloadsStack: View {
    let records: [DownloadRecord]
    let downloads: DownloadsController

    /// The icon column is centred on the Library button; text starts at 63 pt.
    static let iconSize: CGFloat = 40
    static let leading: CGFloat = 6
    static let iconSpacing: CGFloat = 17
    static let trailing: CGFloat = 28

    var body: some View {
        let now = Date()
        VStack(spacing: 0) {
            ForEach(Array(records.enumerated()).reversed(), id: \.element.id) { index, record in
                RecentDownloadRow(record: record, time: RecentDownloads.relativeTime(record.updatedAt, now: now)) {
                    downloads.perform(.open, on: record.id)
                }
                .modifier(QuickViewRowPose(fromBottom: index))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent Downloads")
    }
}

/// Drives the quick view's open and close. The transition animates the
/// phase's elapsed time linearly; each row turns it into its own pose with
/// `DownloadsQuickView.pose`, so the curves and stagger are Arc's measured
/// ones rather than a spring's. Reduce Motion fades only.
enum QuickViewMotion {
    static func transition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .modifier(active: QuickViewClockModifier(.opening, elapsed: 0),
                                 identity: QuickViewClockModifier(.opening, elapsed: DownloadsQuickView.openDuration))
                .animation(.linear(duration: DownloadsQuickView.openDuration)),
            removal: .modifier(active: QuickViewClockModifier(.closing, elapsed: DownloadsQuickView.closeDuration),
                               identity: QuickViewClockModifier(.closing, elapsed: 0))
                .animation(.linear(duration: DownloadsQuickView.closeDuration)))
    }

    /// The update pill gives way within a few frames and comes back once the stack has gone.
    static func pill(reduceMotion: Bool, showingDownloads: Bool) -> Animation {
        showingDownloads ? .easeOut(duration: 0.06)
            : .easeIn(duration: 0.15).delay(reduceMotion ? 0 : DownloadsQuickView.closeDuration)
    }
}

private struct QuickViewClock: Equatable {
    var phase: DownloadsQuickView.Phase
    var elapsed: TimeInterval
}

private struct QuickViewClockKey: EnvironmentKey {
    static let defaultValue: QuickViewClock? = nil
}

private extension EnvironmentValues {
    var quickViewClock: QuickViewClock? {
        get { self[QuickViewClockKey.self] }
        set { self[QuickViewClockKey.self] = newValue }
    }
}

private struct QuickViewClockModifier: ViewModifier, Animatable {
    var phase: DownloadsQuickView.Phase
    var animatableData: TimeInterval

    init(_ phase: DownloadsQuickView.Phase, elapsed: TimeInterval) {
        self.phase = phase
        animatableData = elapsed
    }

    func body(content: Content) -> some View {
        content.environment(\.quickViewClock, QuickViewClock(phase: phase, elapsed: animatableData))
    }
}

/// Reads the clock here rather than in the row, so a frame redraws only the offset and opacity.
private struct QuickViewRowPose: ViewModifier {
    let fromBottom: Int
    @Environment(\.quickViewClock) private var clock

    func body(content: Content) -> some View {
        let pose = clock.map { DownloadsQuickView.pose($0.phase, fromBottom: fromBottom, elapsed: $0.elapsed) } ?? .rest
        content
            .offset(y: pose.offset)
            .opacity(pose.opacity)
    }
}

private struct RecentDownloadRow: View {
    let record: DownloadRecord
    let time: String
    let open: () -> Void
    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        HStack(spacing: RecentDownloadsStack.iconSpacing) {
            DownloadFileIcon(fileName: record.fileName, path: record.targetPath, size: RecentDownloadsStack.iconSize, kind: .thumbnail)
            VStack(alignment: .leading, spacing: 0) {
                Text(record.fileName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(chrome.title)
                Text(time)
                    .font(.system(size: 12))
                    .foregroundStyle(chrome.secondaryText)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, RecentDownloadsStack.leading)
        .padding(.trailing, RecentDownloadsStack.trailing)
        .frame(height: CGFloat(DownloadsQuickView.rowPitch))
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isHovering ? MediaStripMetrics.hover(dark: chrome.isDark) : .clear)
            .padding(.horizontal, 2))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .onDrag { Self.dragProvider(for: record.targetPath) }
        .help(record.targetPath)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(record.fileName), \(time)")
    }

    /// The file for a drag, from its path and extension alone:
    /// `NSItemProvider(contentsOf:)` reads its type from disk on the main
    /// thread, which blocks on a slow or protected volume.
    static func dragProvider(for path: String) -> NSItemProvider {
        let url = URL(fileURLWithPath: path)
        let provider = NSItemProvider(object: url as NSURL)
        if let type = UTType(filenameExtension: url.pathExtension) {
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
                done(url, false, nil)
                return nil
            }
        }
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}

/// Arc's Library button: a 30 pt chip under the pointer, at once and gone as
/// soon as it leaves (the stack lingers on its own timer), and the box pops
/// as the quick view opens.
struct LibraryButton: View {
    let isRevealed: Bool
    let action: () -> Void
    let onHover: (Bool) -> Void
    @State private var isHovering = false
    /// Bumped on each reveal only, so the box pops on open and not on close.
    @State private var reveals = 0
    @Environment(\.themeChrome) private var chrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let chipSize: CGFloat = 30

    var body: some View {
        Button(action: action) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 14))
                .foregroundStyle(chrome.glyph)
                .symbolEffect(.bounce.up, options: .speed(1.4), value: reveals)
                .frame(width: 18, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(chrome.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.08))
                        .frame(width: Self.chipSize, height: Self.chipSize)
                        .opacity(isHovering ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.065)) { isHovering = hovering }
            onHover(hovering)
        }
        .onChange(of: isRevealed) { _, revealed in
            if revealed, !reduceMotion { reveals += 1 }
        }
    }
}
