import Foundation

/// When a sidebar hover preview opens and closes: the tab card (P3.5) and
/// the folder list (P3.8). The sidebar feeds it pointer events and keeps one
/// timer set for `nextDeadline`; `tick` says what to do when it fires.
public struct HoverPreviewTimer<ID: Hashable>: Equatable {
    public enum Kind: Equatable { case tab, folder }

    public enum Action: Equatable {
        case none
        /// Open (or move) the preview to this row.
        case show(ID)
        case hide
    }

    /// Arc opens a collapsed folder's list sooner than a tab's card.
    public static func delay(for kind: Kind) -> TimeInterval {
        switch kind {
        case .tab: return 0.8
        case .folder: return 0.5
        }
    }

    /// Moving on from an open preview opens the next one almost at once.
    public static var warmDelay: TimeInterval { 0.1 }
    /// How long after a preview closes the next one still opens warm.
    public static var warmWindow: TimeInterval { 0.4 }
    /// Time to cross the gap from the row to the preview without it closing.
    public static var closeGrace: TimeInterval { 0.25 }

    public private(set) var pending: ID?
    public private(set) var pendingDeadline: Date?
    public private(set) var shown: ID?
    public private(set) var closeDeadline: Date?
    private var lastClosedAt: Date?

    public init() {}

    /// The earliest time `tick` has something to do.
    public var nextDeadline: Date? {
        switch (pendingDeadline, closeDeadline) {
        case let (open?, close?): return min(open, close)
        case let (open?, nil): return open
        case let (nil, close?): return close
        case (nil, nil): return nil
        }
    }

    /// The pointer entered a row that may preview.
    public mutating func pointerEntered(_ id: ID, kind: Kind, now: Date) {
        if shown == id {
            closeDeadline = nil
            pending = nil
            pendingDeadline = nil
            return
        }
        let warm = shown != nil || lastClosedAt.map { now.timeIntervalSince($0) < Self.warmWindow } == true
        pending = id
        pendingDeadline = now.addingTimeInterval(warm ? Self.warmDelay : Self.delay(for: kind))
    }

    /// The pointer left a row: a wait for it ends; its open preview closes
    /// after the grace unless the pointer reaches the preview.
    public mutating func pointerExited(_ id: ID, now: Date) {
        if pending == id {
            pending = nil
            pendingDeadline = nil
        }
        if shown == id { closeDeadline = now.addingTimeInterval(Self.closeGrace) }
    }

    /// The pointer moved onto or off the open preview.
    public mutating func previewHovered(_ hovering: Bool, now: Date) {
        guard shown != nil else { return }
        closeDeadline = hovering ? nil : now.addingTimeInterval(Self.closeGrace)
    }

    /// A click, scroll, drag or menu: nothing opens and an open preview
    /// closes now, without warming the next one.
    public mutating func cancel() -> Action {
        let wasShown = shown != nil
        pending = nil
        pendingDeadline = nil
        shown = nil
        closeDeadline = nil
        lastClosedAt = nil
        return wasShown ? .hide : .none
    }

    /// The timer fired. A row the caller can no longer preview (selected,
    /// expanded, gone) is refused through `canShow`.
    public mutating func tick(now: Date, canShow: (ID) -> Bool = { _ in true }) -> Action {
        if let id = pending, let deadline = pendingDeadline, deadline <= now {
            pending = nil
            pendingDeadline = nil
            if canShow(id) {
                shown = id
                closeDeadline = nil
                return .show(id)
            }
        }
        if shown != nil, let deadline = closeDeadline, deadline <= now {
            shown = nil
            closeDeadline = nil
            lastClosedAt = now
            return .hide
        }
        return .none
    }
}

/// Snapshots for tab hover cards, one per tab. A tab is captured at most
/// once per `maxAge` for the same page, failures included, so hovering
/// back and forth never captures again; the least recently stored entries
/// go first past `capacity`.
public struct TabSnapshotCache<Image> {
    public struct Entry {
        public var image: Image?
        public var url: URL
        public var capturedAt: Date
    }

    public let capacity: Int
    public let maxAge: TimeInterval
    public private(set) var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var inFlight: Set<UUID> = []

    public init(capacity: Int = 24, maxAge: TimeInterval = 120) {
        self.capacity = capacity
        self.maxAge = maxAge
    }

    /// The snapshot of this page, however old; nil for another page.
    public func image(for id: UUID, url: URL) -> Image? {
        guard let entry = entries[id], entry.url == url else { return nil }
        return entry.image
    }

    public func shouldCapture(_ id: UUID, url: URL, now: Date) -> Bool {
        guard !inFlight.contains(id) else { return false }
        guard let entry = entries[id], entry.url == url else { return true }
        return now.timeIntervalSince(entry.capturedAt) >= maxAge
    }

    public mutating func beginCapture(_ id: UUID) {
        inFlight.insert(id)
    }

    /// Stores a capture's result; nil records a failure, which also waits `maxAge`.
    public mutating func store(_ image: Image?, for id: UUID, url: URL, now: Date) {
        inFlight.remove(id)
        let kept = image ?? (entries[id]?.url == url ? entries[id]?.image : nil)
        entries[id] = Entry(image: kept, url: url, capturedAt: now)
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
    }

    public mutating func remove(_ id: UUID) {
        entries[id] = nil
        order.removeAll { $0 == id }
        inFlight.remove(id)
    }
}
