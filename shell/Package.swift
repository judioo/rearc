// swift-tools-version: 5.10
import PackageDescription

// Chromium engine integration is opt-in at manifest evaluation time. With
// neither variable set this is the WebKit-only shell and needs no engine build.
// scripts/bundle-chromium.sh sets both (and uses its own scratch path):
//   REARC_CHROMIUM_OUT    Chromium output dir containing Chromium.app.
//   REARC_ENGINE_INCLUDE  Dir holding rearc_engine_abi.h, rearc_engine_entry_mac.h
//                         and the ReArcEngine module.modulemap.
let chromiumOut = Context.environment["REARC_CHROMIUM_OUT"]
let engineInclude = Context.environment["REARC_ENGINE_INCLUDE"]

var packageDependencies: [Package.Dependency] = []
var reArcDependencies: [Target.Dependency] = ["SidebarModel", "Onboarding"]

var reArcSwiftSettings: [SwiftSetting] = []
var reArcLinkerSettings: [LinkerSetting] = []
if let chromiumOut, let engineInclude {
    packageDependencies = [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")]
    reArcDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
    reArcSwiftSettings = [
        .define("REARC_CHROMIUM"),
        .unsafeFlags(["-I", engineInclude]),
    ]
    reArcLinkerSettings = [
        // Link against the app-embedded framework so its own rpath resolves the
        // component dylib closure next to Chromium.app at link time. Weak, so a
        // Chromium-enabled binary still launches (WebKit only) outside the bundle.
        .unsafeFlags([
            "-F", "\(chromiumOut)/Chromium.app/Contents/Frameworks",
            "-Xlinker", "-weak_framework", "-Xlinker", "Chromium Framework",
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        ]),
    ]
}

let package = Package(
    name: "ReArcShell",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "rearc", targets: ["ReArc"]),
        .library(name: "SidebarModel", targets: ["SidebarModel"]),
        .executable(name: "arc-vs-rearc", targets: ["ArcBench"]),
        .executable(name: "sunrise", targets: ["SunrisePrototype"]),
    ],
    dependencies: packageDependencies,
    targets: [
        // Pure-Swift model layer: no SwiftUI/AppKit/WebKit imports.
        .target(name: "SidebarModel"),
        // Native shell: SwiftUI chrome + WKWebView (default) or Chromium behind
        // the WebEngine protocol.
        .executableTarget(
            name: "ReArc",
            dependencies: reArcDependencies,
            swiftSettings: reArcSwiftSettings,
            linkerSettings: reArcLinkerSettings
        ),
        // Arc vs ReArc from outside (docs/ARC-VS-REARC-BENCH.md): the pure
        // frame-diff, timing, stats and report code, and the command-line tool
        // that posts keys and captures one window (scripts/arc-vs-rearc.sh).
        .target(name: "ArcBenchCore"),
        .executableTarget(
            name: "ArcBench",
            dependencies: ["ArcBenchCore", "SidebarModel"]
        ),
        // First-run onboarding: the sunrise (Act 0) scene, its score and the
        // full-screen takeover. `sunrise` runs it on its own and renders previews.
        .target(
            name: "Onboarding",
            dependencies: ["SidebarModel"],
            resources: [.copy("Resources/voice-placeholder.wav")],
            // The score is synthesised sample by sample on the real-time audio
            // thread. Unoptimised, Act 1 needs more than its 10.7 ms per 512-frame
            // buffer, so a debug build drops buffers and the soundtrack crackles.
            // Optimise this module in every configuration.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .executableTarget(
            name: "SunrisePrototype",
            dependencies: ["Onboarding"]
        ),
        .testTarget(
            name: "OnboardingTests",
            dependencies: ["Onboarding"]
        ),
        .testTarget(
            name: "ArcBenchCoreTests",
            dependencies: ["ArcBenchCore"]
        ),
        .testTarget(
            name: "SidebarModelTests",
            dependencies: ["SidebarModel"]
        ),
        .testTarget(
            name: "ReArcTests",
            dependencies: ["ReArc", "SidebarModel", "Onboarding"]
        ),
    ]
)
