import AppKit
import SidebarModel
import SwiftUI

/// The sidebar's downloads button: an arrow that fills a progress ring while
/// files transfer, pulses when one starts, and shows an orange dot when a
/// download needs attention. Click for the tray.
struct DownloadsButton: View {
    let downloads: DownloadsController
    let isPresented: Binding<Bool>
    /// Opens Library › Downloads (the popover lists only the newest rows).
    var showAll: (() -> Void)?
    @State private var pulse = false

    var body: some View {
        Button { isPresented.wrappedValue.toggle() } label: {
            ZStack {
                if let fraction = downloads.activeFraction {
                    Circle()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(fraction, 0.03))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.25), value: fraction)
                } else if downloads.activeCount > 0 {
                    // Unknown total: an indeterminate spinner ring.
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(downloads.activeCount > 0 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .offset(y: pulse ? 2 : 0)
            }
            .frame(width: 18, height: 18)
            .overlay(alignment: .topTrailing) {
                if downloads.hasDangerous {
                    Circle().fill(Color.orange).frame(width: 6, height: 6).offset(x: 2, y: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onChange(of: downloads.startCount) { _, _ in
            withAnimation(.spring(duration: 0.18, bounce: 0.6)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.spring(duration: 0.3, bounce: 0.4)) { pulse = false }
            }
        }
        .popover(isPresented: isPresented, arrowEdge: .top) {
            DownloadsTrayView(downloads: downloads, showAll: showAll)
        }
    }

    private var helpText: String {
        let active = downloads.activeCount
        return active > 0 ? "Downloads — \(active) in progress" : "Downloads"
    }
}

/// The tray popover: recent downloads newest first, with progress and
/// per-row actions; the folder downloads are saved to; Clear.
struct DownloadsTrayView: View {
    /// Rows the popover lists. It is open while a download starts, which is
    /// when Chromium replays its history: every update copied and diffed a
    /// `ForEach` over the whole list. The Library lists every row.
    static let popoverLimit = DownloadList.defaultLimit

    let downloads: DownloadsController
    /// On the Library's Downloads page: full width and height, no title.
    var embedded = false
    /// The Library column's search (`LibraryDownloads.matching`).
    var query = ""
    /// The popover's "Show All" (Library › Downloads); nil hides it.
    var showAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !embedded { Text("Downloads").font(.headline) }
                Spacer()
                Menu {
                    Button("Show Download Folder") { downloads.revealDirectory() }
                    Button("Change Download Folder…") { downloads.chooseDirectory() }
                    Divider()
                    Toggle("Ask Where to Save Each File", isOn: Binding(
                        get: { downloads.askWhereToSave },
                        set: { downloads.askWhereToSave = $0 }
                    ))
                    .disabled(!downloads.canAskWhereToSave)
                } label: {
                    Label(downloads.directory.lastPathComponent, systemImage: "folder")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Saved to \(downloads.directory.path)")
                Button("Clear") { downloads.clearFinished() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(!downloads.hasFinished)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            let matching = downloads.matching(query)
            let records = embedded ? matching[...] : matching.prefix(Self.popoverLimit)
            if records.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(downloads.records.isEmpty ? "No downloads yet" : "No matches").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(records) { record in
                            DownloadRowView(record: record, downloads: downloads)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: embedded ? .infinity : 360)
                if !embedded, matching.count > records.count, let showAll {
                    Divider()
                    Button("Show All \(matching.count) Downloads", action: showAll)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
        }
        .frame(width: embedded ? nil : 340)
    }
}

struct DownloadRowView: View {
    let record: DownloadRecord
    let downloads: DownloadsController
    @State private var hovering = false
    @State private var confirmingKeep = false

    /// Waiting for Keep or Discard (Chromium's warning, or the danger code).
    private var isWarned: Bool { downloads.needsDecision(record) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(record.fileName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(record.state == .cancelled, color: .secondary)
                if record.isActive, !isWarned {
                    ProgressView(value: record.fractionCompleted ?? 0)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(record.isPaused ? .secondary : .accentColor)
                        .opacity(record.fractionCompleted == nil ? 0.4 : 1)
                }
                Text(downloads.warningText(for: record) ?? record.statusText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(statusStyle)
                    .lineLimit(1)
                if isWarned {
                    dangerActions
                }
            }
            Spacer(minLength: 4)
            if !isWarned { trailingActions }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isWarned ? Color.orange.opacity(0.1) : Color.primary.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if record.hasFileOnDisk { downloads.perform(.open, on: record.id) } }
        .contextMenu { contextMenu }
        .help(record.url)
    }

    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            DownloadFileIcon(fileName: record.fileName, path: record.hasFileOnDisk ? record.targetPath : "", size: 30)
                .opacity(record.state == .complete || record.isActive ? 1 : 0.5)
            if isWarned {
                badge("exclamationmark.triangle.fill", .orange)
            } else if record.state == .interrupted {
                badge("exclamationmark.circle.fill", .red)
            }
        }
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11))
            .foregroundStyle(.white, color)
            .offset(x: 3, y: 3)
    }

    private var statusStyle: AnyShapeStyle {
        if isWarned { return AnyShapeStyle(Color.orange) }
        if record.state == .interrupted { return AnyShapeStyle(Color.red) }
        return AnyShapeStyle(.secondary)
    }

    @ViewBuilder
    private var trailingActions: some View {
        HStack(spacing: 2) {
            if record.isActive {
                if record.isPaused {
                    rowButton("play.fill", "Resume", enabled: record.canResume) { downloads.perform(.resume, on: record.id) }
                } else {
                    rowButton("pause.fill", "Pause") { downloads.perform(.pause, on: record.id) }
                }
                rowButton("xmark", "Cancel") { downloads.perform(.cancel, on: record.id) }
            } else if record.state == .interrupted, record.canResume {
                rowButton("arrow.clockwise", "Resume") { downloads.perform(.resume, on: record.id) }
            } else if record.hasFileOnDisk {
                rowButton("magnifyingglass", "Show in Finder") { downloads.perform(.reveal, on: record.id) }
            }
        }
        .opacity(hovering || record.isActive ? 1 : 0.55)
    }

    private var dangerActions: some View {
        HStack(spacing: 8) {
            Button("Discard", role: .destructive) { downloads.discard(record.id) }
                .controlSize(.small)
            if downloads.canKeep(record) {
                Button("Keep…") { confirmingKeep = true }
                    .controlSize(.small)
                    .help("Save this file even though it may be harmful")
                    .confirmationDialog(
                        "Keep \(record.fileName)?",
                        isPresented: $confirmingKeep
                    ) {
                        Button("Keep Anyway", role: .destructive) { downloads.keep(record.id) }
                        Button("Discard") { downloads.discard(record.id) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("\(downloads.warningText(for: record) ?? "This file may be harmful"). Only keep it if you trust its source.")
                    }
            } else if downloads.canReviewDangerous {
                Button("Review…") { downloads.reviewDangerousPage?() }
                    .controlSize(.small)
                    .help("Keep or discard it on the Downloads page")
            }
        }
        .padding(.top, 2)
    }

    private func rowButton(_ symbol: String, _ help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .help(help)
    }

    @ViewBuilder
    private var contextMenu: some View {
        if record.hasFileOnDisk {
            Button("Open") { downloads.perform(.open, on: record.id) }
            Button("Show in Finder") { downloads.perform(.reveal, on: record.id) }
            Divider()
        }
        if record.isActive {
            if record.isPaused {
                Button("Resume") { downloads.perform(.resume, on: record.id) }.disabled(!record.canResume)
            } else if !isWarned {
                Button("Pause") { downloads.perform(.pause, on: record.id) }
            }
            Button("Cancel") { downloads.perform(.cancel, on: record.id) }
            Divider()
        }
        Button("Copy Download Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.url, forType: .string)
        }
        Button("Remove from List") { downloads.perform(.remove, on: record.id) }
    }
}

/// A download's icon: its type's at once, then the file's own (or a
/// QuickLook thumbnail) once `DownloadFileService` has read it off the main
/// thread. An empty `path` (no file yet, or not finished) keeps the type's.
/// Scrolling the row away cancels its read.
struct DownloadFileIcon: View {
    let fileName: String
    let path: String
    let size: CGFloat
    var kind: DownloadFileService.ImageKind = .icon
    @State private var loaded: NSImage?
    @State private var loadedKey: String?
    @Environment(\.displayScale) private var scale

    private var pixels: Int { Int((size * scale).rounded(.up)) }
    private var key: String { "\(path)|\(pixels)|\(kind)" }

    var body: some View {
        let service = DownloadFileService.shared
        let image = (loadedKey == key ? loaded : nil)
            ?? (path.isEmpty ? nil : service.cachedImage(atPath: path, pixels: pixels, kind: kind))
            ?? service.placeholder(forFileName: fileName)
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: key) {
                guard !path.isEmpty else { return }
                let key = key
                let image = await service.image(atPath: path, pixels: pixels, kind: kind)
                guard !Task.isCancelled, let image else { return }
                loaded = image
                loadedKey = key
            }
    }
}
