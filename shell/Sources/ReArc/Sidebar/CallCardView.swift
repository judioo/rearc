import AppKit
import SwiftUI
import SidebarModel

/// Arc's call card (the Google Meet card): the strip's 33 pt card with the
/// tab's favicon and title (back to the tab) and camera and microphone
/// toggles. State comes from the tab's `MediaCaptureState` (ABI 1.46); a
/// toggle is enabled only where the page handles its media session action and
/// reports the state it flips, because mute is the page's own (the engine asks
/// the page; it never disables a track itself). Not wired in: the caller
/// decides placement and supplies the actions.
struct CallCardView: View {
    let title: String
    let favicon: NSImage?
    let faviconToken: String
    let capture: MediaCaptureState
    let goToTab: () -> Void
    let toggle: (MediaCaptureState.Device) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: goToTab) {
                HStack(spacing: 8) {
                    SiteIconView(image: favicon, token: faviconToken, size: 16)
                    CallCardTitle(title: title)
                }
                .padding(.leading, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to Tab")
            .accessibilityLabel("Go to \(title)")
            CallCardToggle(device: .camera, capture: capture) { toggle(.camera) }
            CallCardToggle(device: .microphone, capture: capture) { toggle(.microphone) }
                .padding(.trailing, 4)
        }
        .frame(height: MediaStripMetrics.height)
        .background(MediaStripBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Call controls for \(title)")
    }
}

private struct CallCardTitle: View {
    let title: String
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(chrome.isDark ? Color.white.opacity(0.9) : Color.black.opacity(0.8))
    }
}

/// A camera or microphone toggle: the strip's glyph button, slashed and on a
/// red disc while the device is off (as in Meet's own controls).
struct CallCardToggle: View {
    let device: MediaCaptureState.Device
    let capture: MediaCaptureState
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    private var isOff: Bool { capture.isOff(device) }
    private var enabled: Bool { capture.canToggle(device) }

    private var systemName: String {
        switch device {
        case .camera: isOff ? "video.slash.fill" : "video.fill"
        case .microphone: isOff ? "mic.slash.fill" : "mic.fill"
        }
    }

    private var help: String {
        let name = device == .camera ? "Camera" : "Microphone"
        guard enabled else { return "\(name) \(isOff ? "Off" : "On")" }
        return device == .camera ? (isOff ? "Turn On Camera" : "Turn Off Camera")
            : (isOff ? "Unmute Microphone" : "Mute Microphone")
    }

    private var disc: Color {
        if isOff { return Color.red.opacity(enabled ? (isHovering ? 0.9 : 0.8) : 0.35) }
        return isHovering && enabled ? MediaStripMetrics.hover(dark: chrome.isDark) : .clear
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: device == .camera ? 11 : 12))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isOff ? Color.white : MediaStripMetrics.glyph(dark: chrome.isDark, enabled: enabled))
                .frame(width: 26, height: 26)
                .background(Circle().fill(disc))
                .frame(width: 30, height: MediaStripMetrics.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isOff)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(device == .camera ? "callCardCameraToggle" : "callCardMicrophoneToggle")
    }
}
