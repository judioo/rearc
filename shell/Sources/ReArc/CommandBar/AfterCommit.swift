import CoreFoundation
import Foundation

/// Runs main-thread work once the current frame has been committed: the
/// command bar's engine lookups wait here, so a keystroke's frame carries its
/// local results without Chromium's synchronous omnibox passes in front of
/// it. Work scheduled before the commit runs once, straight after it, in
/// order; keys typed faster than frames schedule into the same turn.
final class AfterCommit {
    /// Core Animation commits at this order before the run loop waits.
    static let coreAnimationCommitOrder = 2_000_000

    private var work: [() -> Void] = []
    private var observer: CFRunLoopObserver?
    /// Bumped by every flush, so a fallback only runs its own round.
    private var round = 0
    /// Work also runs this long after scheduling if the run loop has not
    /// waited by then.
    var fallbackDelay: TimeInterval = 0.05

    var isPending: Bool { !work.isEmpty }

    func schedule(_ body: @escaping () -> Void) {
        work.append(body)
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, false, Self.coreAnimationCommitOrder + 1) { [weak self] _, _ in
            self?.flush()
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let round = self.round
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) { [weak self] in
            guard let self, self.round == round else { return }
            self.flush()
        }
    }

    /// Runs everything scheduled so far (tests call it in place of a frame).
    func flush() {
        round &+= 1
        if let observer {
            CFRunLoopObserverInvalidate(observer)
            self.observer = nil
        }
        let pending = work
        work = []
        pending.forEach { $0() }
    }

    /// Drops scheduled work.
    func cancel() {
        work = []
    }
}
