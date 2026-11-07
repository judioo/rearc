import SwiftUI

extension View {
    /// Makes a drawn control a real button, so it looks the same but presses
    /// with a click, with VoiceOver (AXPress) and with Space under Full
    /// Keyboard Access. A tap gesture with the button trait only gets the click.
    func sunriseButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { self }
            .buttonStyle(SunriseButtonStyle())
            .accessibilityLabel(label)
    }

    /// Whether the controls inside are live. They aren't while they fade in or
    /// out, or in a preview, and then take no clicks, keys or VoiceOver focus.
    func sunriseControlsActive(_ active: Bool) -> some View {
        allowsHitTesting(active)
            .disabled(!active)
            .accessibilityHidden(!active)
    }
}

/// Draws the label as it is: no press dimming, and none when disabled.
struct SunriseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
