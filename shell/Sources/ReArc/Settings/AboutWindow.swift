import AppKit
import ImageIO
import SwiftUI

/// ReArc › About ReArc: Arc's small About window (close only, no title),
/// with the ReArc sting where Arc shows its icon. The sting plays once each
/// time the window opens and rests on its last frame, the sunrise mark and
/// the wordmark; with Reduce Motion it shows only that frame.
final class AboutWindowController: NSWindowController {
    static let width: CGFloat = 360

    /// The WebKit shell's; the Chromium host keeps its own, whose links open tabs there.
    static let shared = AboutWindowController { NSWorkspace.shared.open($0) }

    private let sting = AboutStingView()

    init(openLink: @escaping (URL) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "About ReArc"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        super.init(window: window)
        let hosting = NSHostingView(rootView: AboutView(sting: sting, openLink: openLink))
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        if window?.isVisible != true { sting.play() }
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The versions the release script stamps into Info.plist (RELEASE.md, "Versioning").
enum AboutInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let marketing = info["CFBundleShortVersionString"] as? String ?? "–"
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return "Version \(marketing)" }
        return "Version \(marketing) (\(build))"
    }

    static var engine: String? {
        (Bundle.main.infoDictionary?["ReArcEngineVersion"] as? String).map { "Chromium Engine Version \($0)" }
    }

    static var copyright: String {
        "Copyright © \(Calendar.current.component(.year, from: Date())) Imara Ani LLC. All rights reserved."
    }
}

private struct AboutView: View {
    let sting: AboutStingView
    let openLink: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            AboutStingRepresentable(view: sting)
                .frame(width: AboutWindowController.width,
                       height: (AboutWindowController.width * AboutStingView.aspect).rounded())
            VStack(spacing: 4) {
                Text(AboutInfo.version)
                if let engine = AboutInfo.engine { Text(engine) }
                Text(AboutInfo.copyright)
                    .padding(.top, 10)
                Text(attribution)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .environment(\.openURL, OpenURLAction { url in
                        openLink(url)
                        return .handled
                    })
            }
            .font(.system(size: 11))
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .frame(width: AboutWindowController.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var attribution: AttributedString {
        var text = (try? AttributedString(markdown:
            "ReArc is made possible by the [Chromium](https://www.chromium.org) open source project, "
            + "as well as other [open source software](https://github.com/judioo/rearc).")) ?? AttributedString()
        for run in text.runs where run.link != nil {
            text[run.range].underlineStyle = .single
        }
        return text
    }
}

private struct AboutStingRepresentable: NSViewRepresentable {
    let view: AboutStingView
    func makeNSView(context: Context) -> AboutStingView { view }
    func updateNSView(_ nsView: AboutStingView, context: Context) {}
}

/// Resources/AboutSting.gif, played once by NSImageView and then swapped for
/// its last frame, since NSImageView loops whatever the GIF says.
final class AboutStingView: NSImageView {
    static let aspect: CGFloat = 406.0 / 720.0

    private static let url = Bundle.main.url(forResource: "AboutSting", withExtension: "gif")
    private var restTask: DispatchWorkItem?

    private static let frames: (animated: NSImage, last: NSImage, duration: TimeInterval)? = {
        guard let url, let animated = NSImage(contentsOf: url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0, let lastFrame = CGImageSourceCreateImageAtIndex(source, count - 1, nil) else { return nil }
        var duration: TimeInterval = 0
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.04
            duration += delay > 0 ? delay : 0.04
        }
        return (animated, NSImage(cgImage: lastFrame, size: .zero), duration)
    }()

    init() {
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        animates = true
        setAccessibilityLabel("ReArc")
        rest()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func play() {
        guard let frames = Self.frames else {
            image = NSApp.applicationIconImage
            return
        }
        restTask?.cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return rest() }
        // A fresh image restarts the animation from the first frame.
        image = nil
        image = frames.animated
        let task = DispatchWorkItem { [weak self] in self?.rest() }
        restTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + frames.duration, execute: task)
    }

    private func rest() {
        image = Self.frames?.last ?? NSApp.applicationIconImage
    }
}
