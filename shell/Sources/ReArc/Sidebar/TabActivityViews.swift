import SwiftUI
import SidebarModel

/// The row's site icon while its page loads: a ring that fills with the
/// load progress (Arc `ARC_GlowProgressLoadingIndicator`), or a warning
/// glyph when the page crashed.
struct TabActivityIcon<Icon: View>: View {
    let activity: TabActivity
    @ViewBuilder let icon: () -> Icon
    @State private var spin = false

    var body: some View {
        switch activity {
        case .idle:
            icon()
        case .loading(let progress):
            icon()
                .opacity(0.55)
                .overlay {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1.6)
                        Circle()
                            .trim(from: 0, to: max(progress ?? 0.25, 0.12))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .rotationEffect(.degrees(spin ? 270 : -90))
                    }
                    .frame(width: 18, height: 18)
                }
                .onAppear {
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
                }
                .onDisappear { spin = false }
                .help("Loading…")
                .accessibilityLabel("Loading")
        case .crashed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .help("This page crashed — open it to reload")
                .accessibilityLabel("Page crashed")
        }
    }
}

extension View {
    /// The page's load bar along its top edge and, when its renderer is
    /// gone, the crashed-page placeholder with Reload over it.
    func pageStatus(_ activity: TabActivity, onReload: @escaping () -> Void) -> some View {
        overlay(alignment: .top) { PageLoadBar(activity: activity) }
            .overlay {
                if activity == .crashed {
                    CrashedPageView(onReload: onReload)
                        .transition(.opacity)
                }
            }
    }

    /// A transient confirmation capsule at the page's bottom edge.
    func shellToast(_ toast: ShellToast?) -> some View {
        overlay(alignment: .bottom) {
            if let toast {
                Label(toast.message, systemImage: toast.systemImage)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }
}

/// A thin accent bar that follows load progress, then fills and fades.
private struct PageLoadBar: View {
    let activity: TabActivity
    @State private var shownFraction: Double = 0
    @State private var isVisible = false

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.accentColor)
                .shadow(color: Color.accentColor.opacity(0.7), radius: 3)
                .frame(width: proxy.size.width * shownFraction, height: 2.5)
                .opacity(isVisible ? 1 : 0)
        }
        .frame(height: 3)
        .allowsHitTesting(false)
        .onAppear { update(activity.barFraction, animated: false) }
        .onChange(of: activity.barFraction) { _, fraction in update(fraction, animated: true) }
    }

    private func update(_ fraction: Double?, animated: Bool) {
        if let fraction {
            if !isVisible { shownFraction = 0 }
            isVisible = true
            withAnimation(animated ? .easeOut(duration: 0.25) : nil) { shownFraction = fraction }
        } else if isVisible {
            withAnimation(.easeOut(duration: 0.2)) { shownFraction = 1 }
            withAnimation(.easeIn(duration: 0.3).delay(0.2)) { isVisible = false }
        }
    }
}

/// Arc's sad tab (`ARC_SadTab`): the renderer is gone, the tab stays.
struct CrashedPageView: View {
    let onReload: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("This page crashed")
                .font(.title2.weight(.semibold))
            Text("Something went wrong while showing it. Your tab is still here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Reload", action: onReload)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
