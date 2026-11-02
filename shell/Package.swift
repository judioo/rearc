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

var reArcSwiftSettings: [SwiftSetting] = []
var reArcLinkerSettings: [LinkerSetting] = []
if let chromiumOut, let engineInclude {
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
    ],
    targets: [
        // Pure-Swift model layer: no SwiftUI/AppKit/WebKit imports.
        .target(name: "SidebarModel"),
        // Native shell: SwiftUI chrome + WKWebView (default) or Chromium behind
        // the WebEngine protocol.
        .executableTarget(
            name: "ReArc",
            dependencies: ["SidebarModel"],
            swiftSettings: reArcSwiftSettings,
            linkerSettings: reArcLinkerSettings
        ),
        .testTarget(
            name: "SidebarModelTests",
            dependencies: ["SidebarModel"]
        ),
        .testTarget(
            name: "ReArcTests",
            dependencies: ["ReArc", "SidebarModel"]
        ),
    ]
)
