import AppKit
import QuickLookThumbnailing
import SwiftUI
import SidebarModel

/// The slot between the media stack and the bottom bar for Arc's "New Arc
/// Version Available" pill (ARC-RECORDING-2026-11-06.md §2 rule 6). Empty
/// until an updater sets `BrowserViewModel.availableUpdate`.
struct UpdateBannerSlot: View {
    let update: AvailableUpdate?
    let install: () -> Void
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        if let update {
            Button(action: install) {
                Text(AvailableUpdate.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(chrome.title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(Capsule(style: .continuous).fill(chrome.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.07)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Install version \(update.version)")
            .padding(.horizontal, MediaStripMetrics.inset)
            .padding(.top, 2)
        }
    }
}

/// The Library button's hover stack (§5.1): the latest downloads, directly
/// above the bottom bar. Click a row to open the file, drag it out to drag
/// the file.
struct RecentDownloadsStack: View {
    let records: [DownloadRecord]
    let downloads: DownloadsController

    var body: some View {
        let now = Date()
        VStack(spacing: 0) {
            ForEach(records) { record in
                RecentDownloadRow(record: record, time: RecentDownloads.relativeTime(record.updatedAt, now: now)) {
                    downloads.perform(.open, on: record.id)
                }
            }
        }
        .padding(4)
        .background(MediaStripBackground())
        .padding(.horizontal, MediaStripMetrics.inset)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent Downloads")
    }
}

private struct RecentDownloadRow: View {
    let record: DownloadRecord
    let time: String
    let open: () -> Void
    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        HStack(spacing: 8) {
            DownloadThumbnail(path: record.targetPath, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(time)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isHovering ? MediaStripMetrics.hover(dark: chrome.isDark) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: record.targetPath)) ?? NSItemProvider() }
        .help(record.targetPath)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(record.fileName), \(time)")
    }
}

/// A QuickLook thumbnail of the file, with its Finder icon until (or unless) one arrives.
private struct DownloadThumbnail: View {
    let path: String
    let size: CGFloat
    @State private var thumbnail: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: path) {
                let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path),
                                                           size: CGSize(width: size, height: size), scale: scale,
                                                           representationTypes: .thumbnail)
                thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            }
    }
}
