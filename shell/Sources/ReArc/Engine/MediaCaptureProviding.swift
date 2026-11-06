import Combine
import SidebarModel

/// Engines that report a tab's camera and microphone use (Chromium
/// `media_capture`, ABI 1.46), for the sidebar's call card.
protocol MediaCaptureProviding: AnyObject {
    var mediaCapturePublisher: AnyPublisher<MediaCaptureState, Never> { get }
    /// Asks the page to flip a device; false when it can't (no handler).
    @discardableResult
    func toggleCapture(_ device: MediaCaptureState.Device) -> Bool
}
