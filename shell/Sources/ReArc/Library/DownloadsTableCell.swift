import AppKit
import SidebarModel

/// One download in Library › Downloads, drawn with plain AppKit views
/// (perf-8): the file's icon with a warning or failure badge, its name
/// (struck through when cancelled), a transfer's bar, the status or warning
/// text, and the row's buttons (pause, resume, cancel, retry, Show in Finder;
/// Discard and Keep or Review on a warned row). It draws what
/// `DownloadRowView` drew, on one 48 pt pitch.
///
/// The icon is the type's at once and the file's own once
/// `DownloadFileService` has read it off the main thread; a reused cell drops
/// the last row's read.
final class DownloadsTableCell: NSView {
    private(set) var record: DownloadRecord?
    private weak var controller: DownloadsTableController?
    private var warned = false
    private var canKeep = false
    private var canReview = false
    var isHovered = false { didSet { if isHovered != oldValue { updateButtonOpacity() } } }

    private let icon = NSImageView()
    private let badge = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let track = CALayer()
    private let bar = CALayer()
    private var buttons: [DownloadsRowButton] = []
    private let discard = NSButton(title: "Discard", target: nil, action: nil)
    private let keep = NSButton(title: "Keep…", target: nil, action: nil)
    private var iconKey: String?
    private var iconTask: Task<Void, Never>?

    static let nameFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    static let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let nameHeight = ceil(NSLayoutManager().defaultLineHeight(for: nameFont))
    private static let statusHeight = ceil(NSLayoutManager().defaultLineHeight(for: statusFont))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        addSubview(icon)
        badge.imageScaling = .scaleNone
        addSubview(badge)

        name.font = Self.nameFont
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.cell?.usesSingleLineMode = true
        addSubview(name)

        status.font = Self.statusFont
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 1
        status.cell?.usesSingleLineMode = true
        addSubview(status)

        track.cornerRadius = 1.5
        bar.cornerRadius = 1.5
        layer?.addSublayer(track)
        layer?.addSublayer(bar)

        for button in [discard, keep] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
            addSubview(button)
        }
        discard.hasDestructiveAction = true
        discard.action = #selector(discardPressed)
        keep.action = #selector(keepPressed)

        for view in [icon, badge, name, status] as [NSView] { view.setAccessibilityElement(false) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // MARK: Configuration

    func configure(_ record: DownloadRecord, controller: DownloadsTableController) {
        let old = self.record
        self.record = record
        self.controller = controller
        let downloads = controller.downloads
        warned = downloads.needsDecision(record)
        canKeep = warned && downloads.canKeep(record)
        canReview = warned && !canKeep && downloads.canReviewDangerous

        if old?.fileName != record.fileName || old?.state != record.state {
            if record.state == .cancelled {
                name.attributedStringValue = NSAttributedString(string: record.fileName, attributes: [
                    .font: Self.nameFont, .foregroundColor: NSColor.labelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: NSColor.secondaryLabelColor,
                ])
            } else {
                name.stringValue = record.fileName
                name.textColor = .labelColor
            }
        }
        let text = downloads.warningText(for: record) ?? record.statusText
        if status.stringValue != text { status.stringValue = text }
        status.textColor = warned ? .systemOrange : record.state == .interrupted ? .systemRed : .secondaryLabelColor
        if toolTip != record.url { toolTip = record.url }

        icon.alphaValue = record.state == .complete || record.isActive ? 1 : 0.5
        badge.image = warned ? Self.warningBadge : record.state == .interrupted ? Self.failureBadge : nil
        badge.isHidden = badge.image == nil

        configureButtons(record)
        discard.isHidden = !warned
        keep.isHidden = !(canKeep || canReview)
        keep.title = canKeep ? "Keep…" : "Review…"
        keep.toolTip = canKeep ? "Save this file even though it may be harmful" : "Keep or discard it on the Downloads page"
        updateProgress()
        loadIcon()
        needsLayout = true
    }

    /// `DownloadRowView`'s trailing buttons; none on a warned row.
    private func configureButtons(_ record: DownloadRecord) {
        var wanted: [(String, String, DownloadAction, Bool)] = []
        if !warned {
            if record.isActive {
                if record.isPaused {
                    wanted.append(("play.fill", "Resume", .resume, record.canResume))
                } else {
                    wanted.append(("pause.fill", "Pause", .pause, true))
                }
                wanted.append(("xmark", "Cancel", .cancel, true))
            } else if record.state == .interrupted, record.canResume {
                wanted.append(("arrow.clockwise", "Resume", .resume, true))
            } else if record.hasFileOnDisk {
                wanted.append(("magnifyingglass", "Show in Finder", .reveal, true))
            }
        }
        while buttons.count < wanted.count {
            let button = DownloadsRowButton()
            button.target = self
            button.action = #selector(rowButtonPressed(_:))
            addSubview(button)
            buttons.append(button)
        }
        for (index, button) in buttons.enumerated() {
            guard index < wanted.count else {
                button.isHidden = true
                continue
            }
            let (symbol, help, action, enabled) = wanted[index]
            button.isHidden = false
            button.configure(symbol: symbol, help: help, action: action)
            button.isEnabled = enabled
        }
        updateButtonOpacity()
    }

    private func updateButtonOpacity() {
        let alpha: CGFloat = isHovered || record?.isActive == true ? 1 : 0.55
        for button in buttons where button.alphaValue != alpha { button.alphaValue = alpha }
    }

    private func updateProgress() {
        guard let record, record.isActive, !warned else {
            track.isHidden = true
            bar.isHidden = true
            return
        }
        track.isHidden = false
        bar.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            bar.backgroundColor = (record.isPaused ? NSColor.secondaryLabelColor : NSColor.controlAccentColor).cgColor
        }
        // An unknown total shows an empty, faded bar.
        track.opacity = record.fractionCompleted == nil ? 0.4 : 1
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateProgress()
    }

    // MARK: Icon

    private var pixels: Int { Int((DownloadsTableMetrics.iconSize * (window?.backingScaleFactor ?? 2)).rounded(.up)) }

    private func loadIcon() {
        guard let record else { return }
        let path = record.hasFileOnDisk ? record.targetPath : ""
        let pixels = pixels
        let key = "\(path)|\(record.fileName)|\(pixels)"
        guard key != iconKey else { return }
        iconKey = key
        iconTask?.cancel()
        iconTask = nil
        let service = DownloadFileService.shared
        if !path.isEmpty, let cached = service.cachedImage(atPath: path, pixels: pixels, kind: .icon) {
            icon.image = cached
            return
        }
        icon.image = Self.placeholder(forFileName: record.fileName, pixels: pixels)
        guard !path.isEmpty else { return }
        iconTask = Task { [weak self] in
            let image = await service.image(atPath: path, pixels: pixels, kind: .icon)
            guard !Task.isCancelled, let self, self.iconKey == key, let image else { return }
            self.icon.image = image
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The backing scale may differ from the guess made before the cell had a window.
        if window != nil { loadIcon() }
    }

    /// Type icons drawn once at the row's size: the workspace's icons draw
    /// their images lazily, which a fling would do on every new row.
    private static var placeholders: [String: NSImage] = [:]

    static func placeholder(forFileName fileName: String, pixels: Int) -> NSImage {
        let key = "\((fileName as NSString).pathExtension.lowercased())|\(pixels)"
        if let image = placeholders[key] { return image }
        let source = DownloadFileService.shared.placeholder(forFileName: fileName)
        let size = NSSize(width: DownloadsTableMetrics.iconSize, height: DownloadsTableMetrics.iconSize)
        let image = SystemDownloadFiles.render(source, pixels: pixels).map { NSImage(cgImage: $0, size: size) } ?? source
        placeholders[key] = image
        return image
    }

    private static func badgeImage(_ symbol: String, _ color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, color])))
    }

    private static let warningBadge = badgeImage("exclamationmark.triangle.fill", .systemOrange)
    private static let failureBadge = badgeImage("exclamationmark.circle.fill", .systemRed)

    // MARK: Layout

    override func layout() {
        super.layout()
        let inset = DownloadsTableMetrics.listInset + DownloadsTableMetrics.rowPadding
        let midY = bounds.midY
        let size = DownloadsTableMetrics.iconSize
        icon.frame = NSRect(x: inset, y: midY - size / 2, width: size, height: size)
        badge.frame = NSRect(x: inset + size - 14 + 3, y: midY + size / 2 - 14 + 3, width: 14, height: 14)

        var trailing = bounds.width - inset
        if warned {
            for button in [keep, discard] where !button.isHidden {
                button.sizeToFit()
                let width = button.frame.width
                trailing -= width
                button.frame = NSRect(x: trailing, y: (midY - button.frame.height / 2).rounded(), width: width, height: button.frame.height)
                trailing -= 4
            }
        } else {
            let button = DownloadsTableMetrics.buttonSize
            for view in buttons.prefix(while: { !$0.isHidden }).reversed() {
                trailing -= button
                view.frame = NSRect(x: trailing, y: midY - button / 2, width: button, height: button)
                trailing -= 2
            }
        }
        let textX = inset + size + DownloadsTableMetrics.iconToText
        let textWidth = max(0, trailing - 4 - textX)
        let showsBar = !bar.isHidden
        let barHeight: CGFloat = 3
        let gap: CGFloat = showsBar ? 2 : 3
        let block = Self.nameHeight + gap + Self.statusHeight + (showsBar ? barHeight + gap : 0)
        var y = (midY - block / 2).rounded()
        name.frame = NSRect(x: textX - 2, y: y, width: textWidth + 4, height: Self.nameHeight)
        y += Self.nameHeight + gap
        if showsBar, let record {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.frame = CGRect(x: textX, y: y, width: textWidth, height: barHeight)
            bar.frame = CGRect(x: textX, y: y, width: textWidth * (record.fractionCompleted ?? 0), height: barHeight)
            CATransaction.commit()
            y += barHeight + gap
        }
        status.frame = NSRect(x: textX - 2, y: y, width: textWidth + 4, height: Self.statusHeight)
    }

    // MARK: Actions

    @objc private func rowButtonPressed(_ sender: DownloadsRowButton) {
        guard let record, let action = sender.downloadAction else { return }
        controller?.perform(action, on: [record.id])
    }

    @objc private func discardPressed() {
        guard let record else { return }
        controller?.downloads.discard(record.id)
    }

    @objc private func keepPressed() {
        guard let record, let controller else { return }
        if canKeep {
            controller.keep(record, from: self)
        } else {
            controller.downloads.reviewDangerousPage?()
        }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { record != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        guard let record else { return nil }
        var parts = [record.fileName, status.stringValue]
        if record.state == .cancelled { parts[1] = "Cancelled" }
        if warned { parts.append("Needs a decision") }
        return parts.joined(separator: ", ")
    }

    override func accessibilityHelp() -> String? { record?.url }

    override func accessibilityPerformPress() -> Bool {
        guard let record, record.hasFileOnDisk else { return false }
        controller?.perform(.open, on: [record.id])
        return true
    }

    /// The row's menu, for VoiceOver's actions rotor.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let record, let controller else { return nil }
        return controller.menuItems(for: [record]).filter { !$0.isSeparatorItem && $0.isEnabled }.map { item in
            NSAccessibilityCustomAction(name: item.title) {
                guard let action = item.action else { return false }
                return NSApp.sendAction(action, to: item.target, from: item)
            }
        }
    }
}

/// A row's round button: a 10 pt bold symbol on a faint circle.
final class DownloadsRowButton: NSButton {
    private(set) var downloadAction: DownloadAction?
    private var symbol = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = DownloadsTableMetrics.buttonSize / 2
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(symbol: String, help: String, action: DownloadAction) {
        downloadAction = action
        if toolTip != help {
            toolTip = help
            setAccessibilityLabel(help)
        }
        guard symbol != self.symbol else { return }
        self.symbol = symbol
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }
}
