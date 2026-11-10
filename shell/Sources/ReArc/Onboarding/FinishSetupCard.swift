import SwiftUI

/// A quiet invitation in the sidebar's theme, above the bottom bar. Its
/// close button hides the card; the ReArc menu keeps the way back.
struct FinishSetupCard: View {
    let model: BrowserViewModel
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button { model.showBrowserImport() } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Bring over your tabs from Arc, Chrome or Brave.")
                        .font(.system(size: 12))
                        .foregroundStyle(chrome.title.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Finish setup")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Finish setup. Bring over your tabs from Arc, Chrome or Brave.")
            .accessibilityIdentifier("finishSetupButton")

            Button { model.dismissOnboardingCard() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(chrome.title.opacity(0.6))
            .help("Dismiss — Finish Setting Up ReArc stays in the ReArc menu")
            .accessibilityLabel("Dismiss setup reminder")
            .accessibilityIdentifier("dismissSetupReminder")
        }
        .foregroundStyle(chrome.title)
        .padding(10)
        .background(chrome.title.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(chrome.title.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finishSetupCard")
    }
}
