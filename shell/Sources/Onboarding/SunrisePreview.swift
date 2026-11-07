import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Renders Act 0 offscreen, frame by frame, with its score: no window and no
/// input, so previews never take over the screen.
@MainActor
public enum SunrisePreview {
    public static func renderFrames(_ variant: SunriseVariant, size: CGSize, fps: Double, duration: Double,
                                    reduced: Bool = false, act1: Act1Log? = nil, act2: Act2Log? = nil, act3: Act3Log? = nil, act4: Act4Log? = nil, to dir: URL) throws -> Int {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let count = Int(duration * fps)
        for i in 0 ..< count {
            let t = Double(i) / fps
            let exit = (act4?.handOff ?? act3?.handOff ?? act2?.handOff ?? act1?.handOff).map { Ease.inOut(Ease.progress(t, $0, $0 + SunrisePlayer.exitDuration)) } ?? 0
            let log = act1.flatMap { t >= $0.start ? $0 : nil }
            let view = SunriseSceneView(variant: variant, time: t, reduced: reduced, showsDesktop: true, exit: exit,
                                        act1: log, act2: act2, act3: act3, act4: act4)
                .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.cgImage else { continue }
            let url = dir.appendingPathComponent(String(format: "f%04d.png", i))
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        return count
    }

    public static func renderAudio(_ variant: SunriseVariant, duration: Double, reduced: Bool = false,
                                   act1: Act1Log? = nil, act2: Act2Log? = nil, act3: Act3Log? = nil, act4: Act4Log? = nil, to url: URL) throws {
        let audio = try SunriseAudio(variant: variant, reduced: reduced, offline: true)
        audio.update(SunriseScore.build(act1: act1, act2: act2, act3: act3, act4: act4))
        if let end = act4?.handOff ?? act3?.handOff ?? act2?.handOff ?? act1?.handOff { audio.synth.fadeOutStart = end }
        try audio.render(duration: duration, to: url)
    }
}
