import Foundation

/// One quit's life on the shell side. `ChromiumRuntime` drives it and makes
/// the engine calls and timers; this is the part that decides. A quit either
/// finishes (the engine's terminal completion, then the process exits) or
/// undoes itself (a beforeunload veto, a refused `ReArcEngineShutdown`):
/// it never leaves the runtime stopping while ReArc keeps running.
struct ChromiumQuit: Equatable {
    enum Phase: Equatable {
        case idle
        /// Waiting for closes in flight before `ReArcEngineShutdown` (`ChromiumShutdownGate`).
        case deferred(force: Bool)
        /// `ReArcEngineShutdown` accepted, or being called. `escalated`: the
        /// shell forced it after the deferral bound passed.
        case started(force: Bool, escalated: Bool)
        /// The engine's terminal completion arrived, or the shell gave up on it.
        case ending
    }

    enum Step: Equatable {
        case none
        /// Call `ReArcEngineShutdown(force)`.
        case start(force: Bool)
        /// The quit is over and ReArc keeps running: the runtime is active
        /// again and the shell restores what the quit stopped.
        case undo
        /// Save what `prepareForQuit` saves, then end the process.
        case abandon
    }

    /// How long a quit waits for a profile close in flight before it forces
    /// the engine shutdown. A forced profile close finishes well inside a
    /// second; ten seconds is far past one that is coming.
    static let deferBound: TimeInterval = 10
    /// How long a started shutdown may go with no tab closing before the
    /// process ends. The engine force-closes a tab whose close has not
    /// finished in 30 s (close_controller's deadline), so 45 s without one
    /// means the shutdown will not finish by itself.
    static let stallBound: TimeInterval = 45
    /// The exit code of a quit the shell had to end itself (EX_SOFTWARE).
    static let abandonedExitCode: Int32 = 70

    private(set) var phase = Phase.idle

    var isStopping: Bool { phase != .idle }

    /// How long the current phase may last, from now or from the last progress.
    var bound: TimeInterval? {
        switch phase {
        case .deferred: Self.deferBound
        case .started: Self.stallBound
        case .idle, .ending: nil
        }
    }

    /// A quit request. `mustDefer`: closes in flight would make the engine
    /// busy. A request while a quit is in progress changes nothing; the
    /// bounds end that quit.
    mutating func request(force: Bool, mustDefer: Bool) -> Step {
        guard phase == .idle else { return .none }
        if mustDefer {
            phase = .deferred(force: force)
            return .none
        }
        phase = .started(force: force, escalated: false)
        return .start(force: force)
    }

    /// The closes a deferred quit waited for have finished.
    mutating func becameIdle() -> Step {
        guard case .deferred(let force) = phase else { return .none }
        phase = .started(force: force, escalated: false)
        return .start(force: force)
    }

    /// `ReArcEngineShutdown` refused synchronously. A forced escalation that
    /// is refused ends the process; any other refusal undoes the quit.
    mutating func startRejected() -> Step {
        guard case .started(_, let escalated) = phase else { return .none }
        if escalated {
            phase = .ending
            return .abandon
        }
        phase = .idle
        return .undo
    }

    /// The engine's completion: cancelled is a beforeunload veto.
    mutating func completed(cancelled: Bool) -> Step {
        guard case .started = phase else { return .none }
        if cancelled {
            phase = .idle
            return .undo
        }
        phase = .ending
        return .none
    }

    /// `bound` passed. A deferred quit forces the engine shutdown; a started
    /// one that made no progress ends the process.
    mutating func boundPassed() -> Step {
        switch phase {
        case .deferred:
            phase = .started(force: true, escalated: true)
            return .start(force: true)
        case .started:
            phase = .ending
            return .abandon
        case .idle, .ending:
            return .none
        }
    }
}

/// Where the Chromium runtime is, for the engine a new page gets and for
/// when its engine tab is created.
enum ChromiumRuntimeStage: Equatable {
    /// Chromium does not run in this process (no framework, or it failed to configure).
    case unavailable
    /// `ReArcEngineRun` called, `ready` not yet (the early window).
    case starting
    case ready
    /// A quit is in progress; it ends the process or undoes itself.
    case quitting
    /// `ReArcEngineRun` returned.
    case ended
}

/// The concrete engine of a new page (`EngineHost.makeConcreteEngine`). In a
/// Chromium build every page is Chromium once the engine runs, before ready
/// and during a quit too: its tab waits (`ChromiumTabAdmission`). WebKit is
/// only for a process where Chromium does not run.
enum EngineChoice: Equatable {
    case chromium
    case webKit

    init(chromiumBuild: Bool, stage: ChromiumRuntimeStage) {
        self = chromiumBuild && stage != .unavailable ? .chromium : .webKit
    }
}

/// What `ChromiumRuntime.createTab` does with a request.
enum ChromiumTabAdmission: Equatable {
    case create
    /// Until the runtime is ready, or the quit in progress has undone itself.
    case wait
    /// The engine has stopped: the page shows that its tab is unavailable.
    case refuse

    init(_ stage: ChromiumRuntimeStage) {
        switch stage {
        case .ready: self = .create
        case .starting, .quitting: self = .wait
        case .unavailable, .ended: self = .refuse
        }
    }
}

/// The browser shell's side of a quit (`ChromiumShell.terminating`): set when
/// the quit starts, cleared when it undoes itself.
struct ShellTermination: Equatable {
    private(set) var isTerminating = false

    /// True when this starts the quit: save the window session now.
    mutating func begin() -> Bool {
        defer { isTerminating = true }
        return !isTerminating
    }

    mutating func cancel() {
        isTerminating = false
    }
}
