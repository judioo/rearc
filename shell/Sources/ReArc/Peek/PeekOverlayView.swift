import SwiftUI

/// In-window preview chrome over the content area (~70% of available space).
struct PeekOverlayView: View {
    @Environment(\.themeChrome) private var themeChrome
    let title: String
    let url: URL
    let webContent: AnyView
    let onOpenInTab: () -> Void
    let onOpenInLittleArc: () -> Void
    let onCopyLink: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)

                VStack(spacing: 0) {
                    header
                    Divider()
                    webContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(
                    width: proxy.size.width * 0.70,
                    height: proxy.size.height * 0.70
                )
                // Tinted by the focused space (THEMES.md §3.6; roles still to confirm, §8).
                .background(themeChrome.panel, in: RoundedRectangle(cornerRadius: 14))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
                .shadow(color: .black.opacity(0.28), radius: 28, y: 10)
            }
        }
        .onExitCommand(perform: onDismiss)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Open in Little ReArc", action: onOpenInLittleArc)
            Button("Open in full tab", action: onOpenInTab)
            Button("Copy link", action: onCopyLink)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
