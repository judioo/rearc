import SwiftUI
import SidebarModel

/// The bench's presentation markers for a browser window (PresentationProbe).
/// Each marker is its own view, so it re-renders exactly when the state it
/// reports changes, in the same update as the views that show that state.
/// Nothing is built unless `--rearc-bench` enabled the probe.
struct BrowserProbeMarkers: View {
    let model: BrowserViewModel
    let pager: SpacePagerController

    var body: some View {
        if PresentationProbe.shared.isEnabled {
            ZStack {
                SidebarProbe(model: model)
                SpaceProbe(model: model)
                PagerProbe(pager: pager)
                TabProbe(model: model)
                CommandBarProbe(model: model)
                CommandBarResultsProbe(model: model)
                SwitcherProbe(model: model)
                PeekProbe(model: model)
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// "shown" / "hidden", "+peek" while the floating sidebar shows.
private struct SidebarProbe: View {
    let model: BrowserViewModel
    var body: some View {
        ProbeMarker(name: "sidebar", token: (model.isSidebarVisible ? "shown" : "hidden") + (model.isSidebarPeeking ? "+peek" : ""))
    }
}

/// The active space and its profile.
private struct SpaceProbe: View {
    let model: BrowserViewModel
    var body: some View {
        ProbeMarker(name: "space", token: "\(model.store.activeSpaceID.uuidString)|\(model.store.activeProfileID.uuidString)")
    }
}

/// The space pager: "moving" during a switch animation, "rest" once settled.
private struct PagerProbe: View {
    let pager: SpacePagerController
    var body: some View {
        ProbeMarker(name: "pager", token: pager.isAnimating ? "moving" : "rest")
    }
}

/// The selected tab (sidebar highlight).
private struct TabProbe: View {
    let model: BrowserViewModel
    var body: some View {
        ProbeMarker(name: "tab", token: model.store.selectedTabID?.uuidString ?? "-")
    }
}

/// Presented, and the field's text.
private struct CommandBarProbe: View {
    let model: BrowserViewModel
    var body: some View {
        ProbeMarker(name: "commandbar", token: model.isCommandBarPresented ? "open|" + model.commandBarText : "closed")
    }
}

/// The text and the live results shown for it: `text|liveQuery|history|suggestions`.
private struct CommandBarResultsProbe: View {
    let model: BrowserViewModel
    var body: some View {
        let live = model.commandBarLive
        ProbeMarker(name: "results", token: "\(model.commandBarText)|\(live?.query ?? "-")|\(live?.history?.count ?? -1)|\(live?.suggestions.count ?? 0)")
    }
}

private struct SwitcherProbe: View {
    let model: BrowserViewModel
    var body: some View {
        ProbeMarker(name: "switcher", token: model.tabSwitcher == nil ? "closed" : "open")
    }
}

private struct PeekProbe: View {
    let model: BrowserViewModel
    var body: some View {
        ProbeMarker(name: "peek", token: model.peekSession?.url.absoluteString ?? "-")
    }
}

/// A Little Arc window's first frame: its window ID.
struct LittleArcProbeMarker: View {
    let windowID: LittleArcWindow.ID
    var body: some View {
        if PresentationProbe.shared.isEnabled {
            ProbeMarker(name: "littlearc", token: windowID.uuidString).frame(width: 0, height: 0)
        }
    }
}
