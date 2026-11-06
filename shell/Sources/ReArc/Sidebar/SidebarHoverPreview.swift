import AppKit
import SwiftUI
import SidebarModel

/// Hover previews for one sidebar list: a tab's card (P3.5) and a collapsed
/// folder's list of children (P3.8). Plain row cells report the pointer
/// here; the state stays in this object, not the model, so hovering costs
/// one timer and no observation.
final class SidebarHoverPreview: NSObject, NSPopoverDelegate {
    private weak var controller: SidebarListController?
    private var timer = HoverPreviewTimer<UUID>()
    private var wake: Timer?
    private var anchors: [UUID: Weak<SidebarPlainRowCell>] = [:]
    private var popover: NSPopover?
    private var clickMonitor: Any?

    init(controller: SidebarListController) {
        self.controller = controller
    }

    // MARK: From the rows

    func pointerEntered(_ cell: SidebarPlainRowCell, id: UUID, kind: SidebarOutlineNode.Kind) {
        guard let previewKind = Self.previewKind(kind), canPreview(id, kind: previewKind) else { return }
        anchors = anchors.filter { $0.value.value != nil }
        anchors[id] = Weak(cell)
        timer.pointerEntered(id, kind: previewKind, now: Date())
        if previewKind == .tab { TabHoverSnapshots.shared.captureSelectedTab(of: controller?.model) }
        reschedule()
    }

    func pointerExited(_ id: UUID) {
        timer.pointerExited(id, now: Date())
        reschedule()
    }

    /// A press, scroll, drag or menu closes the preview at once.
    func cancel() {
        if timer.cancel() == .hide { close() }
        reschedule()
    }

    // MARK: Timing

    private func reschedule() {
        wake?.invalidate()
        wake = nil
        updateClickMonitor()
        guard let deadline = timer.nextDeadline else { return }
        let wake = Timer(fire: max(deadline, Date()), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        RunLoop.main.add(wake, forMode: .common)
        self.wake = wake
    }

    private func fire() {
        let action = timer.tick(now: Date()) { [weak self] id in self?.canShow(id) ?? false }
        switch action {
        case .show(let id): show(id)
        case .hide: close()
        case .none: break
        }
        reschedule()
    }

    private static func previewKind(_ kind: SidebarOutlineNode.Kind) -> HoverPreviewTimer<UUID>.Kind? {
        switch kind {
        case .tab: return .tab
        case .folder: return .folder
        default: return nil
        }
    }

    /// Selected tabs and expanded or empty folders have nothing to preview.
    private func canPreview(_ id: UUID, kind: HoverPreviewTimer<UUID>.Kind) -> Bool {
        guard let controller, !controller.hostsAllRows, !controller.isLiveScrolling, !controller.isMenuTracking else { return false }
        let store = controller.model.store
        switch (kind, store.entry(withID: id)) {
        case (.tab, .tab(let tab)?):
            return !store.isSelected(tab.id, inSpace: controller.spaceID)
        case (.folder, .folder(let folder)?):
            return !store.isFolderExpanded(folder.id) && !folder.children.isEmpty
        default:
            return false
        }
    }

    private func canShow(_ id: UUID) -> Bool {
        guard let cell = anchors[id]?.value, cell.rowID == id, cell.window != nil,
              NSApp.isActive, NSEvent.pressedMouseButtons == 0,
              let kind = controller?.model.store.entry(withID: id).flatMap(Self.kind(of:)) else { return false }
        return canPreview(id, kind: kind)
    }

    private static func kind(of entry: SidebarEntry) -> HoverPreviewTimer<UUID>.Kind? {
        switch entry {
        case .tab: return .tab
        case .folder: return .folder
        default: return nil
        }
    }

    // MARK: The popover

    private func show(_ id: UUID) {
        guard let controller, let cell = anchors[id]?.value else { return }
        let model = controller.model
        let root: AnyView
        switch model.store.entry(withID: id) {
        case .tab(let tab)?:
            let image = TabHoverSnapshots.shared.image(for: tab)
            root = AnyView(TabHoverCard(tab: tab, image: image, onHover: { [weak self] in self?.previewHovered($0) }))
        case .folder(let folder)?:
            root = AnyView(FolderHoverList(folder: folder, model: model, onHover: { [weak self] in self?.previewHovered($0) },
                                           onPick: { [weak self] in self?.cancel() }))
        default:
            return
        }
        let popover = self.popover ?? makePopover()
        popover.contentViewController = NSHostingController(rootView: root)
        // On an open popover this moves it to the new row.
        popover.show(relativeTo: cell.bounds, of: cell, preferredEdge: .maxX)
        self.popover = popover
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        return popover
    }

    private func close() {
        popover?.performClose(nil)
        popover = nil
    }

    private func previewHovered(_ hovering: Bool) {
        timer.previewHovered(hovering, now: Date())
        reschedule()
    }

    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === popover { popover = nil }
    }

    /// While something is pending or open, a click outside the preview closes it.
    private func updateClickMonitor() {
        let wanted = timer.pending != nil || timer.shown != nil
        if wanted, clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let inPreview = event.window != nil && event.window === self.popover?.contentViewController?.view.window
                    if !inPreview { self.cancel() }
                }
                return event
            }
        } else if !wanted, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    func invalidate() {
        wake?.invalidate()
        _ = timer.cancel()
        close()
        updateClickMonitor()
    }
}

private struct Weak<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}

// MARK: - Snapshots

/// Hover-card snapshots for every window. Only the selected tab is
/// captured: it is the one on screen, and a hidden page has no reliable
/// pixels. Reaching another row to click it means hovering a tab row, which
/// captures the tab being left, at most once per page per
/// `TabSnapshotCache.maxAge`.
final class TabHoverSnapshots {
    static let shared = TabHoverSnapshots()

    private var cache = TabSnapshotCache<NSImage>()

    func image(for tab: Tab) -> NSImage? {
        cache.image(for: tab.id, url: tab.url)
    }

    func captureSelectedTab(of model: BrowserViewModel?) {
        guard let model, let tab = model.store.selectedTab else { return }
        capture(tab, model: model)
    }

    private func capture(_ tab: Tab, model: BrowserViewModel) {
        let now = Date()
        guard cache.shouldCapture(tab.id, url: tab.url, now: now),
              let engine = model.engineHost.engine(forTabID: tab.id, profileID: model.profileID(for: tab)) else { return }
        cache.beginCapture(tab.id)
        let id = tab.id, url = tab.url
        Task { @MainActor [weak self] in
            let png = try? await engine.captureSnapshot(scope: .visible)
            let image = png.flatMap { Self.thumbnail(from: $0) }
            self?.cache.store(image, for: id, url: url, now: Date())
        }
    }

    /// Cards are 260 pt wide; keeping 2× that bounds the cache's memory.
    private static func thumbnail(from png: Data) -> NSImage? {
        guard let rep = NSBitmapImageRep(data: png), rep.pixelsWide > 0 else { return nil }
        let width = min(CGFloat(rep.pixelsWide), 520)
        let size = NSSize(width: width, height: (width * CGFloat(rep.pixelsHigh) / CGFloat(rep.pixelsWide)).rounded())
        guard let scaled = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(scaled)
        return image
    }
}

// MARK: - Views

/// Arc's hover card: the page's snapshot over its title and host.
private struct TabHoverCard: View {
    let tab: Tab
    let image: NSImage?
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot = image {
                Image(nsImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 260, height: 162, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if let host = tab.url.host() {
                    Text(host)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(width: 280, alignment: .leading)
        .onHover(perform: onHover)
        .accessibilityElement(children: .combine)
    }
}

/// A collapsed folder's children; clicking one shows it.
private struct FolderHoverList: View {
    let folder: SidebarFolder
    let model: BrowserViewModel
    let onHover: (Bool) -> Void
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(folder.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(folder.children.prefix(12), id: \.id) { child in
                FolderHoverListRow(entry: child, model: model) {
                    pick(child)
                }
            }
            if folder.children.count > 12 {
                Text("\(folder.children.count - 12) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
        }
        .padding(6)
        .frame(width: 240, alignment: .leading)
        .onHover(perform: onHover)
    }

    private func pick(_ entry: SidebarEntry) {
        onPick()
        switch entry {
        case .tab(let tab):
            model.selectTab(tab.id)
        case .folder(let child):
            model.store.setFolderExpanded(folder.id, true)
            model.store.setFolderExpanded(child.id, true)
        case .split(let split):
            model.selectSplit(split.id)
        case .easel:
            break
        }
    }
}

private struct FolderHoverListRow: View {
    let entry: SidebarEntry
    let model: BrowserViewModel
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon.frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background {
                if isHovering { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var title: String {
        switch entry {
        case .tab(let tab): return tab.displayTitle
        case .folder(let folder): return folder.title
        case .split(let split): return split.tabs.map(\.displayTitle).joined(separator: " | ")
        case .easel: return "Easel"
        }
    }

    @ViewBuilder private var icon: some View {
        switch entry {
        case .tab(let tab):
            if let favicon = model.favicon(for: tab) {
                Image(nsImage: favicon).resizable().clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Text(tab.faviconToken)
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
            }
        case .folder:
            Image(systemName: "folder").foregroundStyle(.secondary)
        case .split:
            Image(systemName: "rectangle.split.2x1").foregroundStyle(.secondary)
        case .easel:
            Image(systemName: "scribble").foregroundStyle(.secondary)
        }
    }
}
