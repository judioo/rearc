import SwiftUI

/// The deferred-setup invitation above the bottom bar, in the media strips'
/// card (`MediaStripBackground`) so it reads as one of the sidebar's own.
/// The card opens the Import window; its close button hides only the card,
/// and ReArc › Finish Setting Up ReArc… keeps the way back.
struct FinishSetupCard: View {
    let model: BrowserViewModel
    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    private var text: Color { chrome.isDark ? Color.white.opacity(0.9) : Color.black.opacity(0.8) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button { model.showBrowserImport() } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bring over your tabs from Arc, Chrome or Brave.")
                        .font(.system(size: 12))
                        .foregroundStyle(text.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Text("Finish setup")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .offset(x: isHovering ? 2 : 0)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(text)
                }
                .padding(.leading, 11)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Import from another browser")
            .accessibilityLabel("Finish setup. Bring over your tabs from Arc, Chrome or Brave.")
            .accessibilityIdentifier("finishSetupButton")

            FinishSetupDismissButton { model.dismissOnboardingCard() }
                .padding(4)
        }
        .background(MediaStripBackground())
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finishSetupCard")
    }
}

/// The strips' glyph button: a soft disc on hover.
private struct FinishSetupDismissButton: View {
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(MediaStripMetrics.glyph(dark: chrome.isDark))
                .frame(width: 20, height: 20)
                .background(Circle().fill(isHovering ? MediaStripMetrics.hover(dark: chrome.isDark) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("Hide — Finish Setting Up ReArc stays in the ReArc menu")
        .accessibilityLabel("Dismiss setup reminder")
        .accessibilityIdentifier("dismissSetupReminder")
    }
}
