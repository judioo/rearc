import Foundation
import Observation
import SidebarModel

/// What the notice asks of the updater: `AppUpdater` (Sparkle) in a release
/// build, `UpdateNoticePreview` in a build asked to show a state.
@MainActor
protocol UpdateNoticeDriving: AnyObject {
    /// Restart and Update, or Try Again: the center has already sent
    /// `.installRequested`.
    func installFromNotice()
    /// Sparkle's `automaticallyDownloadsUpdates`, the one setting behind the
    /// card's checkbox and Settings' switch.
    var automaticallyDownloadsUpdates: Bool { get set }
}

/// The update notice every browser window's sidebar draws, and the
/// Automatic Updates setting the card and Settings share.
@MainActor
@Observable
final class UpdateNoticeCenter {
    static let shared = UpdateNoticeCenter(preview: UpdateNoticePreview.requestedState())

    private(set) var notice = UpdateNotice()
    /// Mirrors the driver's setting; `automaticUpdatesChanged` keeps it in step.
    private(set) var automaticUpdates = false
    @ObservationIgnored weak var driver: (any UpdateNoticeDriving)? {
        didSet { automaticUpdates = driver?.automaticallyDownloadsUpdates ?? false }
    }
    /// A preview state was asked for: Sparkle stays off (`AppUpdater`).
    let isPreviewing: Bool
    @ObservationIgnored private var preview: UpdateNoticePreview?

    init(preview state: UpdateNoticePreview.State? = nil) {
        isPreviewing = state != nil
        guard let state else { return }
        let preview = UpdateNoticePreview(center: self)
        self.preview = preview
        driver = preview
        preview.show(state)
    }

    func send(_ event: UpdateNotice.Event) {
        notice.send(event)
    }

    /// The update the sidebars show, or nil.
    var sidebarUpdate: AvailableUpdate? { notice.isVisible ? notice.update : nil }

    func install() {
        guard notice.isVisible, !notice.isBusy else { return }
        send(.installRequested)
        driver?.installFromNotice()
    }

    func hide() { send(.hidden) }

    func pointerVisited() {
        if !notice.pointerVisited { send(.pointerVisited) }
    }

    func setAutomaticUpdates(_ on: Bool) {
        guard let driver else { return }
        driver.automaticallyDownloadsUpdates = on
        automaticUpdates = driver.automaticallyDownloadsUpdates
    }

    /// The setting changed under the center (Settings through Sparkle, or
    /// Sparkle itself).
    func automaticUpdatesChanged(_ on: Bool) {
        if automaticUpdates != on { automaticUpdates = on }
    }
}

/// `--rearc-update-notice-preview=STATE` shows the notice in one state with
/// no updater, feed or network: normal, critical, required, ready,
/// downloading, preparing, restarting, offline, signature, nospace,
/// quitrefused. Restart and Update then plays a download and stops at
/// "Restarting ReArc…": nothing installs and nothing quits. Like the
/// self-test it runs only where verification may (a development build, or a
/// verification bundle with `REARC_RELEASE_VERIFICATION=1`); a shipped
/// bundle ignores the flag.
@MainActor
final class UpdateNoticePreview: UpdateNoticeDriving {
    enum State: String, CaseIterable {
        case normal, critical, required, ready, downloading, preparing, restarting
        case offline, signature, nospace, quitrefused
    }

    nonisolated static let flagPrefix = "--rearc-update-notice-preview="

    nonisolated static func requestedState(arguments: [String] = CommandLine.arguments,
                                           environment: [String: String] = ProcessInfo.processInfo.environment,
                                           infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> State? {
        guard let argument = arguments.dropFirst().last(where: { $0.hasPrefix(flagPrefix) }) else { return nil }
        guard EngineLaunchOptions.allowsVerification(infoDictionary: infoDictionary, environment: environment) else {
            FileHandle.standardError.write(Data("ReArc: \(flagPrefix)… runs only in a development build or a verification bundle\n".utf8))
            return nil
        }
        return State(rawValue: String(argument.dropFirst(flagPrefix.count)).lowercased())
    }

    private weak var center: UpdateNoticeCenter?
    private var playback: Task<Void, Never>?
    var automaticallyDownloadsUpdates = false

    init(center: UpdateNoticeCenter) {
        self.center = center
    }

    func show(_ state: State) {
        guard let center else { return }
        let urgency: UpdateUrgency = state == .critical ? .critical : state == .required ? .required : .normal
        center.send(.found(AvailableUpdate(version: "Preview", build: UpdateBuild(999_999), urgency: urgency),
                           downloaded: state == .ready))
        switch state {
        case .normal, .critical, .required, .ready:
            return
        case .downloading, .preparing, .restarting:
            center.send(.installRequested)
            center.send(.downloadStarted)
            center.send(.downloadExpected(100))
            center.send(.downloadReceived(42))
            if state != .downloading { center.send(.extractionStarted); center.send(.extracted(0.6)) }
            if state == .restarting { center.send(.readyToInstall) }
        case .offline, .signature, .nospace, .quitrefused:
            center.send(.installRequested)
            let failure: UpdateNoticeFailure = switch state {
            case .offline: .offline
            case .signature: .signature
            case .nospace: .noSpace
            default: .quitRefused
            }
            center.send(.failed(failure))
        }
    }

    func installFromNotice() {
        playback?.cancel()
        playback = Task { @MainActor [weak self] in
            guard let center = self?.center else { return }
            if center.notice.phase == .installing { return }
            center.send(.downloadStarted)
            center.send(.downloadExpected(100))
            for _ in 0 ..< 20 {
                try? await Task.sleep(nanoseconds: 75_000_000)
                guard !Task.isCancelled else { return }
                center.send(.downloadReceived(5))
            }
            center.send(.extractionStarted)
            for step in 1 ... 5 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                center.send(.extracted(Double(step) / 5))
            }
            center.send(.readyToInstall)
        }
    }
}
