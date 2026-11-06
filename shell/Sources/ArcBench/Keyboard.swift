import ArcBenchCore
import CoreGraphics
import Darwin
import Foundation

/// Mach absolute time, the clock of CGEvent posts and SCStreamFrameInfo.displayTime.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    static var now: Double { seconds(mach_absolute_time()) }
}

/// Keystrokes posted to the HID event tap, as a keyboard would send them:
/// each modifier down, the key down and up, the modifiers up.
enum Keyboard {
    private static let modifierKeys: [(KeyModifiers, CGKeyCode, CGEventFlags)] = [
        (.control, 59, .maskControl), (.option, 58, .maskAlternate), (.shift, 56, .maskShift), (.command, 55, .maskCommand),
    ]
    /// Modifiers currently held down by `press` (released on cleanup if a signal lands mid-chord).
    private static var held: [(CGKeyCode, CGEventFlags)] = []

    /// Posts `chord` and returns the host time (seconds) of the key-down post.
    static func press(_ chord: KeyChord) -> Double {
        let source = CGEventSource(stateID: .hidSystemState)
        var flags: CGEventFlags = []
        for (modifier, code, flag) in modifierKeys where chord.modifiers.contains(modifier) {
            flags.insert(flag)
            post(source, code, down: true, flags)
            held.append((code, flag))
        }
        var keyFlags = flags
        if chord.isArrow { keyFlags.formUnion([.maskNumericPad, .maskSecondaryFn]) }
        let down = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: true)!
        down.flags = keyFlags
        let posted = HostClock.now
        down.post(tap: .cghidEventTap)
        usleep(16_000)
        post(source, chord.keyCode, down: false, keyFlags)
        usleep(4_000)
        releaseModifiers(source)
        return posted
    }

    static func releaseModifiers(_ source: CGEventSource? = CGEventSource(stateID: .hidSystemState)) {
        var flags = held.reduce(into: CGEventFlags()) { $0.insert($1.1) }
        while let (code, flag) = held.popLast() {
            flags.remove(flag)
            post(source, code, down: false, flags)
        }
    }

    private static func post(_ source: CGEventSource?, _ code: CGKeyCode, down: Bool, _ flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
