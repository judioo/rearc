import Foundation
import os

/// perf-0 os_signpost instrumentation (docs/PERFORMANCE-PLAN.md §2.1), always
/// compiled in: a signposter that nothing records costs a branch. Subsystem
/// `net.rearc.shell`; the engine bridge uses `net.rearc.engine`. Interval
/// names are fixed because Instruments and `xctrace export` group by them.
/// The model layer's intervals (`model`, `persistence`) are `ModelSignposts`
/// in SidebarModel.
enum PerfSignposts {
    static let subsystem = "net.rearc.shell"

    static let interaction = OSSignposter(subsystem: subsystem, category: "interaction")
    static let launch = OSSignposter(subsystem: subsystem, category: "launch")
    static let engineCalls = OSSignposter(subsystem: subsystem, category: "engine-calls")

    /// User-visible interactions, begun where the shortcut, menu item or
    /// monitor lands in the model.
    enum Interaction {
        case sidebarToggle, sidebarPeek, spaceSwitch, profileSwitch, newTab, commandBarOpen, commandBarKey
        case tabSwitch, tabSwitcher, peekOpen, littleArcOpen, windowResize, sidebarScroll

        var name: StaticString {
            switch self {
            case .sidebarToggle: "SidebarToggle"
            case .sidebarPeek: "SidebarPeek"
            case .spaceSwitch: "SpaceSwitch"
            case .profileSwitch: "ProfileSwitch"
            case .newTab: "NewTab"
            case .commandBarOpen: "CommandBarOpen"
            case .commandBarKey: "CommandBarKey"
            case .tabSwitch: "TabSwitch"
            case .tabSwitcher: "TabSwitcher"
            case .peekOpen: "PeekOpen"
            case .littleArcOpen: "LittleArcOpen"
            case .windowResize: "WindowResize"
            case .sidebarScroll: "SidebarScroll"
            }
        }
    }

    /// An interval from the model entry point until the main queue next runs,
    /// which covers the input's synchronous model work. When the frame showing
    /// it is presented is the presentation probe's job, not this interval's.
    static func interaction(_ kind: Interaction, _ detail: @autoclosure () -> String = "") {
        guard interaction.isEnabled else { return }
        let text = detail()
        let state = interaction.beginInterval(kind.name, id: interaction.makeSignpostID(), "\(text, privacy: .public)")
        DispatchQueue.main.async { interaction.endInterval(kind.name, state) }
    }

    /// `launch` events: Main, EngineRunCalled, EarlyWindow, EngineReady,
    /// ModelLoaded, WindowOrderedFront, CachedChromeCommitted, EarlyWindowPresented,
    /// FirstSidebarFrame, FirstPageFrame, FirstInputHandled.
    static func launchEvent(_ name: StaticString) {
        guard launch.isEnabled else { return }
        launch.emitEvent(name)
    }

    /// `interaction` events: InputReceived (event timestamp), Presented (probe, target timestamp).
    static func interactionEvent(_ name: StaticString, _ detail: @autoclosure () -> String) {
        guard interaction.isEnabled else { return }
        let text = detail()
        interaction.emitEvent(name, "\(text, privacy: .public)")
    }

    /// A synchronous engine call from the main thread (`engine-calls`).
    @discardableResult
    static func engineCall<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        guard engineCalls.isEnabled else { return try body() }
        let state = engineCalls.beginInterval(name, id: engineCalls.makeSignpostID())
        defer { engineCalls.endInterval(name, state) }
        return try body()
    }

    /// An engine call that completes later (profile opens, history, autocomplete).
    struct Pending {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState?

        func end() {
            guard let state else { return }
            PerfSignposts.engineCalls.endInterval(name, state)
        }
    }

    static func beginEngineCall(_ name: StaticString) -> Pending {
        guard engineCalls.isEnabled else { return Pending(name: name, state: nil) }
        return Pending(name: name, state: engineCalls.beginInterval(name, id: engineCalls.makeSignpostID()))
    }
}
