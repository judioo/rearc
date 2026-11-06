import Foundation

/// Command-line options of `arc-vs-rearc` (scripts/arc-vs-rearc.sh --help).
public struct Options: Equatable, Sendable {
    public var apps: [AppKind] = [.arc, .rearc]
    public var groups: [String] = ScenarioCatalog.groups
    public var iterations = 20
    public var warmups = 3
    /// Pause between key presses, after the window went quiet.
    public var pauseMs = 600
    /// Before each press the window must have been still this long.
    public var preQuietMs = 300
    public var bundle: String?
    public var out: String?
    public var keepFrames: String?
    public var restartArc = false
    public var dryRun = false
    public var arcSpace = "Demo"
    /// Arc's sidebar at the start: `auto` reads the View menu's Show/Hide Sidebar title.
    public var arcSidebar = "auto"
    public var diff = DiffSettings()
    public var quietMs = 150
    public var timeoutMs = 3000
    public var regions: [String: Region] = [:]
    public var sidebarFraction = 0.22
    /// Capture size as a fraction of the window's size in points.
    public var captureScale = 0.5
    public var lockWaitSeconds = 600
    public var keepData = false
    public var matchArcSize = true

    public init() {}

    public var detection: DetectionSettings {
        DetectionSettings(areaThreshold: diff.areaThreshold, quiet: Double(quietMs) / 1000, timeout: Double(timeoutMs) / 1000)
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// `nil` for `--help`.
    public static func parse(_ arguments: [String]) throws -> Options? {
        var options = Options()
        var pendingRegions: [(String, String)] = []
        var index = 0
        func value(_ name: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw UsageError(description: "\(name) needs a value") }
            return arguments[index]
        }
        func int(_ name: String, _ range: ClosedRange<Int>) throws -> Int {
            let text = try value(name)
            guard let number = Int(text), range.contains(number) else { throw UsageError(description: "\(name): \(text) is not in \(range)") }
            return number
        }
        func double(_ name: String, _ range: ClosedRange<Double>) throws -> Double {
            let text = try value(name)
            guard let number = Double(text), range.contains(number) else { throw UsageError(description: "\(name): \(text) is not in \(range)") }
            return number
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help": return nil
            case "--apps":
                let names = try value(argument).split(separator: ",").map(String.init)
                options.apps = try names.map { name in
                    guard let app = AppKind(rawValue: name) else { throw UsageError(description: "--apps: unknown app \(name) (arc, rearc)") }
                    return app
                }
            case "--scenarios":
                let names = try value(argument).split(separator: ",").map(String.init)
                for name in names where !ScenarioCatalog.groups.contains(name) {
                    throw UsageError(description: "--scenarios: unknown scenario \(name) (\(ScenarioCatalog.groups.joined(separator: ", ")))")
                }
                options.groups = names
            case "--iterations": options.iterations = try int(argument, 1 ... 1000)
            case "--warmups": options.warmups = try int(argument, 0 ... 100)
            case "--pause-ms": options.pauseMs = try int(argument, 0 ... 60000)
            case "--pre-quiet-ms": options.preQuietMs = try int(argument, 0 ... 10000)
            case "--bundle": options.bundle = try value(argument)
            case "--out": options.out = try value(argument)
            case "--keep-frames": options.keepFrames = try value(argument)
            case "--restart-arc": options.restartArc = true
            case "--dry-run": options.dryRun = true
            case "--arc-space": options.arcSpace = try value(argument)
            case "--arc-sidebar":
                let state = try value(argument)
                guard ["auto", "visible", "hidden"].contains(state) else { throw UsageError(description: "--arc-sidebar: auto, visible or hidden") }
                options.arcSidebar = state
            case "--channel-threshold": options.diff.channelThreshold = try int(argument, 0 ... 255)
            case "--area-threshold": options.diff.areaThreshold = try double(argument, 0 ... 1)
            case "--stride": options.diff.stride = try int(argument, 1 ... 64)
            case "--quiet-ms": options.quietMs = try int(argument, 1 ... 10000)
            case "--timeout-ms": options.timeoutMs = try int(argument, 100 ... 60000)
            case "--region":
                let spec = try value(argument)
                guard let equals = spec.firstIndex(of: "=") else { throw UsageError(description: "--region: expected SCENARIO=REGION, got \(spec)") }
                let group = String(spec[..<equals])
                guard ScenarioCatalog.groups.contains(group) else { throw UsageError(description: "--region: unknown scenario \(group)") }
                pendingRegions.append((group, String(spec[spec.index(after: equals)...])))
            case "--sidebar-fraction": options.sidebarFraction = try double(argument, 0.05 ... 0.6)
            case "--capture-scale": options.captureScale = try double(argument, 0.1 ... 2)
            case "--lock-wait": options.lockWaitSeconds = try int(argument, 0 ... 86400)
            case "--keep-data": options.keepData = true
            case "--no-match-size": options.matchArcSize = false
            default: throw UsageError(description: "unknown option: \(argument)")
            }
            index += 1
        }
        // Named regions follow --sidebar-fraction wherever it appears.
        for (group, text) in pendingRegions {
            guard let region = Region.parse(text, sidebarFraction: options.sidebarFraction) else {
                throw UsageError(description: "--region \(group): \(text) is not window, sidebar, content or x0,y0,x1,y1")
            }
            options.regions[group] = region
        }
        return options
    }

    /// Settings echoed into results.json.
    public var summary: [String: String] {
        [
            "apps": apps.map(\.rawValue).joined(separator: ","),
            "scenarios": groups.joined(separator: ","),
            "iterations": "\(iterations)",
            "warmups": "\(warmups)",
            "pause_ms": "\(pauseMs)",
            "pre_quiet_ms": "\(preQuietMs)",
            "channel_threshold": "\(diff.channelThreshold)",
            "area_threshold": "\(diff.areaThreshold)",
            "stride": "\(diff.stride)",
            "quiet_ms": "\(quietMs)",
            "timeout_ms": "\(timeoutMs)",
            "sidebar_fraction": "\(sidebarFraction)",
            "capture_scale": "\(captureScale)",
            "arc_space": arcSpace,
            "arc_sidebar": arcSidebar,
            "regions": regions.keys.sorted().map { key in
                let r = regions[key]!
                return "\(key)=\(r.x0),\(r.y0),\(r.x1),\(r.y1)"
            }.joined(separator: ";"),
        ]
    }
}
