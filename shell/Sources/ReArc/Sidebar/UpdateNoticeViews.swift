import SwiftUI
import SidebarModel

private typealias Metrics = UpdateNoticeMetrics

/// Arc's "New Arc Version Available" pill above the space strip
/// (docs/FEATURE-SPECS/UPDATE-NOTICE.md §2). Resting on it (or focusing it,
/// or pressing it) grows it upward into the card; nothing else in the
/// sidebar moves, the card covers what sits above the pill. Every word is
/// ReArc's own (`UpdateNoticeText`); nothing from the feed is drawn.
struct UpdateNoticePill: View {
    let update: AvailableUpdate
    let install: () -> Void
    @State private var center = UpdateNoticeCenter.shared
    @State private var reveal = HoverReveal(showDelay: Metrics.openDelay, hideDelay: Metrics.closeDelay)
    @State private var revealTask: Task<Void, Never>?
    /// Pressed open (a click, Space, or VoiceOver), until the pointer leaves or Esc.
    @State private var pinned = false
    @FocusState private var focus: UpdateNoticeFocus?
    @Environment(\.themeChrome) private var chrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { reveal.isShown || pinned || focus != nil || center.notice.holdsCardOpen }

    var body: some View {
        let ink = chrome.updateNotice
        let open = isOpen
        let normal = update.urgency == .normal
        Button { pinned.toggle() } label: {
            UpdateNoticeTitle(urgency: update.urgency, tint: normal ? chrome.title : Color(ink.warning))
                .frame(maxWidth: .infinity)
                .frame(height: CGFloat(Metrics.pillHeight))
                .background(normal ? Color(ink.pillFill).opacity(ink.pillFillAlpha) : Color(ink.warningFill).opacity(ink.warningFillAlpha),
                            in: RoundedRectangle(cornerRadius: CGFloat(Metrics.cornerRadius), style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: CGFloat(Metrics.cornerRadius), style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focus, equals: .pill)
        .opacity(open ? 0 : 1)
        .onHover { setHover($0, .trigger) }
        .contextMenu { menu }
        .accessibilityLabel(UpdateNoticeText.title(update.urgency))
        .accessibilityHint("Shows Automatic Updates and Restart and Update")
        .accessibilityAction(named: UpdateNoticeText.install) { install() }
        // The card rises from the pill's bottom edge over the rows above it.
        .overlay(alignment: .bottom) {
            if open {
                UpdateNoticeCard(update: update, center: center, install: install, focus: $focus)
                    .fixedSize(horizontal: false, vertical: true)
                    .onHover { inside in
                        setHover(inside, .content)
                        if inside { center.pointerVisited() }
                    }
                    .onExitCommand { close() }
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .modifier(active: CardReveal(fraction: 0), identity: CardReveal(fraction: 1)),
                        removal: .opacity.animation(.easeOut(duration: Metrics.closeDuration))))
            }
        }
        .animation(open ? .spring(response: Metrics.openResponse, dampingFraction: Metrics.openDamping)
                        : .easeOut(duration: Metrics.closeDuration), value: open)
        .padding(.horizontal, SidebarMetrics.rowInset)
        .padding(.top, 2)
        .padding(.bottom, CGFloat(Metrics.gapAboveStrip))
        .onDisappear { revealTask?.cancel() }
    }

    @ViewBuilder
    private var menu: some View {
        Button(UpdateNoticeText.install, action: install).disabled(center.notice.isBusy)
        if center.notice.canHide {
            Button(UpdateNoticeText.hide) { center.hide() }
        }
    }

    private func setHover(_ hovering: Bool, _ region: HoverReveal.Region) {
        reveal.setHovering(hovering, region, at: ProcessInfo.processInfo.systemUptime)
        revealTask?.cancel()
        // A pressed-open card closes with the pointer's leaving, as a hovered one does.
        guard let deadline = reveal.deadline else {
            // Not yet shown by hover: the card that covers the pill takes the
            // pointer over within a moment, or the pressed card closes.
            guard !hovering, !reveal.isShown, pinned else { return }
            revealTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Metrics.closeDelay * 1_000_000_000))
                if !Task.isCancelled { pinned = false }
            }
            return
        }
        revealTask = Task { @MainActor in
            let wait = max(deadline - ProcessInfo.processInfo.systemUptime, 0)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            reveal.advance(to: max(ProcessInfo.processInfo.systemUptime, deadline))
            if !reveal.isShown { pinned = false }
        }
    }

    private func close() {
        revealTask?.cancel()
        reveal.dismiss()
        pinned = false
        focus = nil
    }
}

/// The mini sidebar's form (⇧⌘S): a glyph in the pill's place, above the
/// stacked bottom bar, that opens the same card as a popover.
struct MiniUpdateNotice: View {
    let model: BrowserViewModel
    @State private var center = UpdateNoticeCenter.shared
    @State private var reveal = HoverReveal(showDelay: Metrics.openDelay, hideDelay: 0.3)
    @State private var revealTask: Task<Void, Never>?
    @State private var pinned = false
    @State private var isHovering = false
    @FocusState private var focus: UpdateNoticeFocus?
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        let form = UpdateNoticePresentation.form(for: center.notice, window: .browser, sidebar: .mini)
        if form == .compact, let update = center.notice.update {
            Button { pinned.toggle() } label: {
                Image(systemName: UpdateNoticeTitle.glyph(update.urgency) ?? "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(update.urgency == .normal ? chrome.accent : Color(chrome.updateNotice.warning))
                    .frame(width: CGFloat(MiniSidebarLayout.highlight), height: LibraryButton.chipSize)
                    .background(chrome.rowHover.opacity(isHovering ? 1 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                isHovering = inside
                setHover(inside, .trigger)
            }
            .help(UpdateNoticeText.title(update.urgency))
            .accessibilityLabel(UpdateNoticeText.title(update.urgency))
            .accessibilityHint("Shows Automatic Updates and Restart and Update")
            .accessibilityAction(named: UpdateNoticeText.install) { center.install() }
            .popover(isPresented: Binding(
                get: { reveal.isShown || pinned },
                set: { if !$0 { close() } }
            ), arrowEdge: model.sidebarPlacement.resizeHandleEdge.edge) {
                UpdateNoticeCard(update: update, center: center, install: { center.install() }, focus: $focus, inPopover: true)
                    .frame(width: 248)
                    .environment(\.themeChrome, chrome)
                    .onHover { inside in
                        setHover(inside, .content)
                        if inside { center.pointerVisited() }
                    }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity)
        }
    }

    private func setHover(_ hovering: Bool, _ region: HoverReveal.Region) {
        reveal.setHovering(hovering, region, at: ProcessInfo.processInfo.systemUptime)
        revealTask?.cancel()
        guard let deadline = reveal.deadline else { return }
        revealTask = Task { @MainActor in
            let wait = max(deadline - ProcessInfo.processInfo.systemUptime, 0)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            reveal.advance(to: max(ProcessInfo.processInfo.systemUptime, deadline))
        }
    }

    private func close() {
        revealTask?.cancel()
        reveal.dismiss()
        pinned = false
    }
}

enum UpdateNoticeFocus: Hashable {
    case pill, checkbox, button
}

/// The pill's and the card's title: a shield for critical, a mark for
/// required, then the level's words.
struct UpdateNoticeTitle: View {
    let urgency: UpdateUrgency
    let tint: Color

    static func glyph(_ urgency: UpdateUrgency) -> String? {
        switch urgency {
        case .normal: nil
        case .critical: "exclamationmark.shield.fill"
        case .required: "exclamationmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if let glyph = Self.glyph(urgency) {
                Image(systemName: glyph).font(.system(size: 11, weight: .semibold))
            }
            Text(UpdateNoticeText.title(urgency))
                .font(.system(size: CGFloat(Metrics.titleSize), weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
    }
}

/// Arc's card: the title, a hairline, Automatic Updates, then Restart and
/// Update in the space's accent. While Sparkle downloads and prepares, the
/// button fills with the progress and waits; a failure is one plain line
/// and Try Again.
struct UpdateNoticeCard: View {
    let update: AvailableUpdate
    let center: UpdateNoticeCenter
    let install: () -> Void
    var focus: FocusState<UpdateNoticeFocus?>.Binding
    var inPopover = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        let ink = chrome.updateNotice
        let notice = center.notice
        let warning = Color(ink.cardWarning)
        let radius = CGFloat(Metrics.cornerRadius)
        VStack(spacing: 0) {
            UpdateNoticeTitle(urgency: update.urgency, tint: update.urgency == .normal ? .primary : warning)
                .frame(maxWidth: .infinity)
                .frame(height: CGFloat(Metrics.pillHeight))
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            if let detail = UpdateNoticeText.detail(update.urgency) {
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(warning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, CGFloat(Metrics.cardInset) + 2)
                    .padding(.top, 7)
            }
            Toggle(isOn: Binding(get: { center.automaticUpdates }, set: { center.setAutomaticUpdates($0) })) {
                Text(UpdateNoticeText.automaticUpdates)
                    .font(.system(size: CGFloat(Metrics.labelSize)))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .focused(focus, equals: .checkbox)
            .frame(height: CGFloat(Metrics.checkboxRowHeight))
            if case let .failed(failure) = notice.phase {
                Text(UpdateNoticeText.failure(failure))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, CGFloat(Metrics.cardInset) + 2)
                    .padding(.bottom, 7)
            }
            UpdateNoticeButton(notice: notice, accent: chrome.accent, title: Color(ink.buttonTitle), action: install)
                .focused(focus, equals: .button)
                .padding(.horizontal, CGFloat(Metrics.cardInset))
                .padding(.bottom, CGFloat(Metrics.cardInset))
        }
        .background {
            if !inPopover {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(ink.card).opacity(ink.cardAlpha))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 1)
            }
        }
        .overlay {
            if !inPopover {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .environment(\.colorScheme, ink.cardIsDark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(UpdateNoticeText.title(update.urgency))
    }
}

/// Restart and Update: the space's accent, filling left to right with the
/// download and the preparing step while it waits.
private struct UpdateNoticeButton: View {
    let notice: UpdateNotice
    let accent: Color
    let title: Color
    let action: () -> Void

    private var fraction: Double? {
        switch notice.phase {
        case let .downloading(progress): progress.fraction ?? 0
        case let .extracting(value): value
        case .installing: 1
        default: nil
        }
    }

    var body: some View {
        let failed = if case .failed = notice.phase { true } else { false }
        let label = notice.isBusy ? (UpdateNoticeText.status(notice.phase) ?? UpdateNoticeText.install)
            : failed ? UpdateNoticeText.retry : UpdateNoticeText.install
        let shape = RoundedRectangle(cornerRadius: CGFloat(Metrics.buttonRadius), style: .continuous)
        Button(action: action) {
            Text(label)
                .font(.system(size: CGFloat(Metrics.buttonTitleSize), weight: .medium))
                .foregroundStyle(title)
                .lineLimit(1)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .frame(height: CGFloat(Metrics.buttonHeight))
                .background {
                    if let fraction {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                accent.opacity(0.45)
                                accent.frame(width: proxy.size.width * fraction)
                            }
                        }
                    } else {
                        accent
                    }
                }
                .clipShape(shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(notice.isBusy)
        .animation(.linear(duration: 0.15), value: fraction)
        .accessibilityLabel(label)
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded(.down))) percent" } ?? "")
    }
}

/// The card's opening: it is uncovered from the pill's height upward while
/// its rows fade in (Arc's recording, ≈ 0.15 s).
private struct CardReveal: ViewModifier, Animatable {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(0.3 + 0.7 * min(max(fraction, 0), 1))
            .mask(alignment: .bottom) {
                GeometryReader { proxy in
                    let pill = CGFloat(Metrics.pillHeight)
                    let height = pill + (proxy.size.height - pill) * CGFloat(min(max(fraction, 0), 1))
                    RoundedRectangle(cornerRadius: CGFloat(Metrics.cornerRadius), style: .continuous)
                        .frame(height: max(height, 0))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
    }
}
