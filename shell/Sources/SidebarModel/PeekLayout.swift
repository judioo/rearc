import CoreGraphics
import Foundation

/// Arc's Peek card, measured from the owner's 2026-11-11 Arc recording
/// (1754 × 1456 px of a 1706 × 1409 pt window at 1 px per pt: the
/// traffic-light pitch is 23 px). The card has no header of its own: a
/// 32 pt address line, then the page. It is centred in the window area beside
/// the sidebar (sidebar edge 330 → window edge 1730, centre 1030; the card's
/// is 1031) and takes 80 % of that width (1120 of 1400 pt). It runs from
/// 12 pt below the window's top edge to 12 pt above its bottom (28 → 1413 in a
/// window spanning 16 → 1425), past the page card's own 7 pt margins. Its top
/// corners are about 7 pt, its bottom ones about 3 pt, with a hairline edge
/// and a soft shadow that fades over about 8 pt.
///
/// Three 34 pt round buttons float outside the card's top-right: 12 pt from
/// its edge, the first 8 pt below its top, on a 43 pt pitch (close 36…70,
/// expand 80…113, split 123…155). A 46 × 4 pt grabber sits centred 4 pt above
/// the card. The page card behind is washed with the window background at
/// about 72 % (white 253 → 240 where the background is 235/229/225); the
/// sidebar is not washed.
///
/// Coordinates are the window's, top-left origin, in points.
public struct PeekLayout: Equatable, Sendable {
    public enum Control: Int, CaseIterable, Sendable {
        case close, expand, split
    }

    /// Outside the card's top-right (Arc), or inside its top-right corner
    /// below the address line when the window is too narrow for both.
    public enum ButtonPlacement: Equatable, Sendable {
        case outside, inside
    }

    public static let widthFraction = 0.8
    public static let verticalInset = 12.0
    public static let addressLineHeight = 32.0
    public static let topCornerRadius = 7.0
    public static let bottomCornerRadius = 3.0
    public static let buttonDiameter = 34.0
    public static let buttonGap = 12.0
    public static let buttonPitch = 43.0
    public static let buttonTopOffset = 8.0
    public static let grabberSize = CGSize(width: 46, height: 4)
    public static let grabberGap = 4.0
    /// The page card's wash behind the Peek: the window background at this opacity.
    public static let backdropWash = 0.72
    /// Beside the card: the buttons, their gap and the same margin again past
    /// them, so they never touch the window edge (12 + 34 + 12).
    public static let minimumSideInset = buttonGap + buttonDiameter + buttonGap
    /// Below this the buttons move inside the card rather than squeeze the page.
    public static let minimumCardWidth = 320.0
    /// The inset that stays when the buttons are inside.
    public static let narrowSideInset = buttonGap

    public let region: CGRect
    public let card: CGRect
    public let buttonPlacement: ButtonPlacement
    /// Close, expand, split, in `Control` order; empty in page fullscreen.
    public let buttons: [CGRect]
    /// Nil when there is no room above the card, and in page fullscreen.
    public let grabber: CGRect?
    /// The page in the Peek is fullscreen: the card fills the window with no chrome.
    public let isFullscreen: Bool

    /// The window area the Peek is centred in: beside a laid-out sidebar,
    /// else the whole window (sidebar hidden or floating, page fullscreen).
    public static func region(windowSize: CGSize, sidebarWidth: Double, sidebarOnLeft: Bool) -> CGRect {
        let width = max(0, Double(windowSize.width))
        let height = max(0, Double(windowSize.height))
        let sidebar = min(max(0, sidebarWidth), width)
        return CGRect(x: sidebarOnLeft ? sidebar : 0, y: 0, width: width - sidebar, height: height)
    }

    public init(region: CGRect, isFullscreen: Bool = false) {
        self.region = region
        self.isFullscreen = isFullscreen
        if isFullscreen {
            card = region
            buttonPlacement = .outside
            buttons = []
            grabber = nil
            return
        }
        let width = Double(region.width)
        let height = max(0, Double(region.height) - 2 * Self.verticalInset)
        let fitted = min(width * Self.widthFraction, width - 2 * Self.minimumSideInset)
        let placement: ButtonPlacement = fitted >= Self.minimumCardWidth ? .outside : .inside
        let cardWidth = placement == .outside ? fitted : max(0, width - 2 * Self.narrowSideInset)
        let card = CGRect(
            x: Double(region.minX) + (width - cardWidth) / 2,
            y: Double(region.minY) + Self.verticalInset,
            width: cardWidth,
            height: height
        )
        self.card = card
        buttonPlacement = placement
        let x = placement == .outside
            ? Double(card.maxX) + Self.buttonGap
            : Double(card.maxX) - Self.buttonGap - Self.buttonDiameter
        let top = Double(card.minY) + Self.buttonTopOffset + (placement == .outside ? 0 : Self.addressLineHeight)
        buttons = Control.allCases.map { control in
            CGRect(x: x, y: top + Double(control.rawValue) * Self.buttonPitch,
                   width: Self.buttonDiameter, height: Self.buttonDiameter)
        }
        let grabberTop = Double(card.minY) - Self.grabberGap - Double(Self.grabberSize.height)
        grabber = grabberTop >= Double(region.minY)
            ? CGRect(x: Double(card.midX) - Double(Self.grabberSize.width) / 2, y: grabberTop,
                     width: Double(Self.grabberSize.width), height: Double(Self.grabberSize.height))
            : nil
    }

    public func frame(of control: Control) -> CGRect? {
        buttons.indices.contains(control.rawValue) ? buttons[control.rawValue] : nil
    }

    /// The control whose round button contains `point`.
    public func control(at point: CGPoint) -> Control? {
        Control.allCases.first { control in
            guard let frame = frame(of: control) else { return false }
            let dx = Double(point.x - frame.midX), dy = Double(point.y - frame.midY)
            return dx * dx + dy * dy <= Self.buttonDiameter * Self.buttonDiameter / 4
        }
    }

    /// The page area under the address line (the whole card in page fullscreen).
    public var page: CGRect {
        guard !isFullscreen else { return card }
        let line = min(Self.addressLineHeight, Double(card.height))
        return CGRect(x: card.minX, y: card.minY + line, width: card.width, height: card.height - line)
    }
}

/// What a click, a key or a button does to an open Peek.
public enum PeekAction: Equatable, Sendable {
    case none
    case close
    case expandToTab
    case openInSplitView
}

public enum PeekInput: Equatable, Sendable {
    /// A click in the window at this point (window coordinates, top-left origin).
    case click(CGPoint)
    /// Esc. The page keeps it while it is fullscreen (Esc leaves fullscreen
    /// first) or while one of its prompts is up over the card.
    case escape(pageFullscreen: Bool, promptOpen: Bool)
    case button(PeekLayout.Control)
    /// ⌘O, Arc's "Open Little Arc or Peek in…".
    case expandShortcut
}

/// Arc closes the Peek on any click outside the card, the sidebar included.
/// That click is taken: it does not also reach what is under it.
public enum PeekDismissal {
    /// `layout` is the open Peek's; without one a click does nothing.
    public static func action(for input: PeekInput, layout: PeekLayout? = nil) -> PeekAction {
        switch input {
        case .click(let point):
            guard let layout, !layout.isFullscreen else { return .none }
            if let control = layout.control(at: point) { return action(for: control) }
            return layout.card.contains(point) ? .none : .close
        case .escape(let pageFullscreen, let promptOpen):
            return pageFullscreen || promptOpen ? .none : .close
        case .button(let control):
            return action(for: control)
        case .expandShortcut:
            return .expandToTab
        }
    }

    private static func action(for control: PeekLayout.Control) -> PeekAction {
        switch control {
        case .close: return .close
        case .expand: return .expandToTab
        case .split: return .openInSplitView
        }
    }
}

/// Arc's Peek grows out of the clicked link and shrinks back into it. At
/// 30 fps the open takes 4–5 frames (blank card, then the page) and the
/// close 3–4, while the page behind washes out over the same time.
public enum PeekMotion {
    public static let openDuration = 0.15
    public static let closeDuration = 0.12
    /// Reduce Motion: a plain fade, no growth.
    public static let fadeDuration = 0.15
    /// The card at its smallest, as a share of its full size, when it grows
    /// out of a click.
    public static let originScale = 0.1
    /// With no click to grow from (the command bar's Peek), it grows out of its own centre.
    public static let centreScale = 0.6

    /// The rect the card grows from and shrinks back to: the card's shape
    /// scaled around the click (kept inside `bounds`), else around its centre.
    public static func originRect(pointer: CGPoint?, card: CGRect, bounds: CGRect) -> CGRect {
        guard card.width > 0, card.height > 0 else { return card }
        guard let pointer, bounds.contains(pointer) else {
            return scaled(card, by: centreScale, around: CGPoint(x: card.midX, y: card.midY))
        }
        var rect = scaled(card, by: originScale, around: pointer)
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return rect
    }

    private static func scaled(_ rect: CGRect, by scale: Double, around centre: CGPoint) -> CGRect {
        let width = Double(rect.width) * scale, height = Double(rect.height) * scale
        return CGRect(x: Double(centre.x) - width / 2, y: Double(centre.y) - height / 2, width: width, height: height)
    }
}

/// A mouse-down while a Peek is open, decided from the event itself in the
/// app's event monitor rather than from a SwiftUI gesture over the embedded
/// pages (which sometimes missed it). Anywhere outside the card and its
/// buttons closes the Peek; the click goes no further.
public enum PeekOutsideClick {
    public enum Outcome: Equatable, Sendable {
        /// Not the Peek's: the window handles it as usual.
        case pass
        /// Close the Peek and take the click.
        case closeAndSwallow
        /// Close the Peek and let the click through: the strip above the
        /// card, where a drag moves the window.
        case closeAndPass
    }

    /// The window edge band that resizes it.
    public static let resizeMargin = 4.0

    /// `point` is in the window's content, top-left origin. `layout` is the
    /// Peek's in that window, nil when the click is in another window (a menu,
    /// a panel, Settings, a Little ReArc) or no Peek shows there.
    /// `windowControls` covers the traffic lights.
    public static func outcome(at point: CGPoint, windowSize: CGSize, layout: PeekLayout?,
                               sheetAttached: Bool, windowControls: CGRect) -> Outcome {
        guard let layout, !layout.isFullscreen, !sheetAttached else { return .pass }
        if layout.card.contains(point) || layout.control(at: point) != nil { return .pass }
        if windowControls.contains(point) { return .pass }
        let margin = CGFloat(resizeMargin)
        if point.x < margin || point.y < margin || point.x > windowSize.width - margin || point.y > windowSize.height - margin {
            return .pass
        }
        return point.y < layout.card.minY ? .closeAndPass : .closeAndSwallow
    }
}
