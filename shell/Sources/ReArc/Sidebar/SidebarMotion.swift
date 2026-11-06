import SwiftUI
import SidebarModel

/// The sidebar's spring (`SpacePaging.Spring.click`: settles in about 0.25 s
/// with no overshoot), for motion that should feel like a space switch.
enum SidebarMotion {
    static func spring(response: Double = SpacePaging.Spring.click.response) -> Animation {
        .spring(response: response, dampingFraction: SpacePaging.Spring.click.dampingFraction)
    }

    /// The spring, or a plain fade of the same length under Reduce Motion.
    static func spring(response: Double = SpacePaging.Spring.click.response, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: min(response, 0.15)) : spring(response: response)
    }
}
