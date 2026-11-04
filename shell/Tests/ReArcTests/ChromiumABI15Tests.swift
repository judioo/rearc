import XCTest
@testable import ReArc
@testable import SidebarModel

final class ChromiumCapabilitiesTests: XCTestCase {
    private let allFeatures: (String) -> Bool = { _ in true }

    func testEngineWithoutMinorExportUsesBaseFeatures() {
        let capabilities = ChromiumCapabilities(abiMinorVersion: nil, hasFeature: allFeatures)
        XCTAssertFalse(capabilities.navigationExtended)
        XCTAssertFalse(capabilities.scriptEvaluation)
        XCTAssertFalse(capabilities.mediaMetadataSnapshot)
        XCTAssertEqual(capabilities.navigationSchemes, [])
    }

    func testMinorBelowFiveIgnoresAdvertisedFeatures() {
        let capabilities = ChromiumCapabilities(abiMinorVersion: 4, hasFeature: allFeatures)
        XCTAssertFalse(capabilities.navigationExtended)
        XCTAssertFalse(capabilities.scriptEvaluation)
        XCTAssertFalse(capabilities.mediaMetadataSnapshot)
    }

    func testMinorFiveRequiresEachFeatureFlag() {
        let capabilities = ChromiumCapabilities(abiMinorVersion: 5) { $0 == "script_evaluation" }
        XCTAssertTrue(capabilities.scriptEvaluation)
        XCTAssertFalse(capabilities.navigationExtended)
        XCTAssertFalse(capabilities.mediaMetadataSnapshot)

        let full = ChromiumCapabilities(abiMinorVersion: 5, hasFeature: allFeatures)
        XCTAssertTrue(full.navigationExtended && full.scriptEvaluation && full.mediaMetadataSnapshot)
        XCTAssertEqual(full.navigationSchemes, .chromium)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 6, hasFeature: allFeatures).scriptEvaluation)
    }
}

final class ChromiumMediaMappingTests: XCTestCase {
    private let playing = WebMediaState(isPlaying: true, isAudible: true, title: "Song", artist: "Band", album: "Record")

    private func snapshot(
        playback: UInt32 = 0,
        audible: Bool = true,
        hasMetadata: Bool,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil
    ) -> ChromiumMediaSnapshot {
        ChromiumMediaSnapshot(playback: playback, audible: audible, hasMetadata: hasMetadata, title: title, artist: artist, album: album)
    }

    func testHasMetadataFalseLeavesMetadataUnchanged() {
        // Even empty strings in the event must not clear metadata when has_metadata is false.
        let next = ChromiumMediaMapping.apply(snapshot(playback: 1, audible: false, hasMetadata: false, title: "", artist: "", album: ""), to: playing)
        // Playback 1 is paused (wave 32); without action bits (below ABI 1.43) both track buttons stay enabled.
        XCTAssertEqual(next, WebMediaState(isPlaying: false, isPaused: true, isAudible: false, title: "Song", artist: "Band", album: "Record",
                                           canPreviousTrack: true, canNextTrack: true))
    }

    func testHasMetadataTrueReplacesAllFieldsTogether() {
        let next = ChromiumMediaMapping.apply(snapshot(hasMetadata: true, title: "Next", artist: "Other", album: "LP"), to: playing)
        XCTAssertEqual(next.title, "Next")
        XCTAssertEqual(next.artist, "Other")
        XCTAssertEqual(next.album, "LP")
    }

    func testAuthoritativeSnapshotClearsWithEmptyOrMissingStrings() {
        let cleared = ChromiumMediaMapping.apply(snapshot(playback: 2, audible: false, hasMetadata: true, title: "", artist: "", album: ""), to: playing)
        XCTAssertEqual(cleared, WebMediaState(isPlaying: false, isAudible: false, canPreviousTrack: true, canNextTrack: true))
        let partial = ChromiumMediaMapping.apply(snapshot(hasMetadata: true, title: "Only title"), to: playing)
        XCTAssertEqual(partial.title, "Only title")
        XCTAssertNil(partial.artist)
        XCTAssertNil(partial.album)
    }

    func testPlaybackAndPictureInPicture() {
        var state = WebMediaState(canPictureInPicture: true)
        for (playback, isPlaying) in [(UInt32(0), true), (1, false), (2, false), (3, false)] {
            state = ChromiumMediaMapping.apply(snapshot(playback: playback, audible: isPlaying, hasMetadata: true), to: state)
            XCTAssertEqual(state.isPlaying, isPlaying, "playback \(playback)")
            XCTAssertEqual(state.isAudible, isPlaying)
            XCTAssertFalse(state.canPictureInPicture)
        }
    }
}

final class ChromiumScriptEvaluationTests: XCTestCase {
    func testWorldArguments() {
        let id = UUID(uuidString: "5E1F7E57-B005-4000-8000-0000000000AA")!
        XCTAssertEqual(ChromiumScriptWorld.editor.abiWorld, 0)
        XCTAssertNil(ChromiumScriptWorld.editor.boostID)
        XCTAssertEqual(ChromiumScriptWorld.boost(id).abiWorld, 0)
        XCTAssertEqual(ChromiumScriptWorld.boost(id).boostID, "5e1f7e57-b005-4000-8000-0000000000aa")
        XCTAssertEqual(ChromiumScriptWorld.page.abiWorld, 1)
        XCTAssertNil(ChromiumScriptWorld.page.boostID)
    }

    func testSuccessDecodesJSONFragments() throws {
        let string = try ChromiumScriptOutcome.decode(status: 0, json: "\"hello\"", errorJSON: nil).get()
        XCTAssertEqual(string as? String, "hello")
        let null = try ChromiumScriptOutcome.decode(status: 0, json: "null", errorJSON: nil).get()
        XCTAssertTrue(null is NSNull)
        let object = try ChromiumScriptOutcome.decode(status: 0, json: #"{"a":[1,true],"b":{"c":"d"}}"#, errorJSON: nil).get() as? [String: Any]
        XCTAssertEqual((object?["a"] as? [Any])?.count, 2)
        XCTAssertEqual((object?["b"] as? [String: String])?["c"], "d")
    }

    func testSuccessWithoutDecodableJSONIsInvalid() {
        XCTAssertThrowsError(try ChromiumScriptOutcome.decode(status: 0, json: nil, errorJSON: nil).get())
        XCTAssertThrowsError(try ChromiumScriptOutcome.decode(status: 0, json: "{", errorJSON: nil).get())
    }

    func testScriptErrorCarriesStructuredDetails() {
        let error = #"{"code":"exception","message":"JavaScript exception","details":{"lineNumber":0,"columnNumber":13}}"#
        let result = ChromiumScriptOutcome.decode(status: ChromiumStatusCode.scriptError, json: nil, errorJSON: error)
        guard case .failure(.script(let info)) = result else { return XCTFail("expected script_error, got \(result)") }
        XCTAssertEqual(info.code, "exception")
        XCTAssertEqual(info.message, "JavaScript exception")
        XCTAssertEqual(info.detailsJSON, #"{"columnNumber":13,"lineNumber":0}"#)
    }

    func testCancelledTimeoutAndOtherStatuses() {
        guard case .failure(.cancelled) = ChromiumScriptOutcome.decode(status: ChromiumStatusCode.cancelled, json: nil, errorJSON: nil),
              case .failure(.timeout) = ChromiumScriptOutcome.decode(status: ChromiumStatusCode.timeout, json: nil, errorJSON: #"{"code":"timeout","message":"t"}"#)
        else { return XCTFail("cancelled/timeout not mapped") }
        let other = ChromiumScriptOutcome.decode(status: ChromiumStatusCode.unsupported, json: nil, errorJSON: "not json")
        guard case .failure(.failed(let status, let info)) = other else { return XCTFail("expected failed, got \(other)") }
        XCTAssertEqual(status, ChromiumStatusCode.unsupported)
        XCTAssertEqual(info, ChromiumScriptErrorInfo(code: "unknown", message: "not json", detailsJSON: nil))
    }
}

final class ChromiumLaunchArgumentsTests: XCTestCase {
    private let key = ChromiumLaunchArguments.devMockKeychainInfoKey
    private let mock = ChromiumLaunchArguments.mockKeychainSwitch

    func testKeychainModeIsOptInAndDebugOnly() {
        XCTAssertEqual(ChromiumLaunchArguments.keychainMode(infoDictionary: nil, isDebugBuild: true), .system)
        XCTAssertEqual(ChromiumLaunchArguments.keychainMode(infoDictionary: [key: false], isDebugBuild: true), .system)
        XCTAssertEqual(ChromiumLaunchArguments.keychainMode(infoDictionary: [key: true], isDebugBuild: true), .devMock)
        XCTAssertEqual(ChromiumLaunchArguments.keychainMode(infoDictionary: [key: true], isDebugBuild: false), .devMockRefused)
    }

    func testMockKeychainSwitchOnlyForDevMock() {
        let base = ["ReArc", "--rearc-selftest"]
        for mode in [ChromiumLaunchArguments.KeychainMode.system, .devMockRefused] {
            XCTAssertFalse(ChromiumLaunchArguments.browserArguments(base, defaultUserDataDir: { "/tmp/p" }, keychain: mode).contains(mock))
        }
        let dev = ChromiumLaunchArguments.browserArguments(base + [mock], defaultUserDataDir: { "/tmp/p" }, keychain: .devMock)
        XCTAssertEqual(dev.filter { $0 == mock }.count, 1)
    }

    func testUserDataDirDefaultsUnlessSupplied() {
        let defaulted = ChromiumLaunchArguments.browserArguments(["ReArc"], defaultUserDataDir: { "/tmp/p" }, keychain: .system)
        XCTAssertEqual(defaulted, ["ReArc", "--user-data-dir=/tmp/p"])
        let supplied = ChromiumLaunchArguments.browserArguments(["ReArc", "--user-data-dir=/x"], defaultUserDataDir: {
            XCTFail("default should not be computed")
            return ""
        }, keychain: .system)
        XCTAssertEqual(supplied, ["ReArc", "--user-data-dir=/x"])
    }
}

final class BoostEditorScriptsTests: XCTestCase {
    func testExpressionsAreIIFEsThatBootstrapThePicker() {
        let source = BoostEditorScripts.snapshotAt(x: 12, y: 34.5)
        XCTAssertTrue(source.hasPrefix("(function(){"))
        XCTAssertTrue(source.hasSuffix("})()"))
        XCTAssertTrue(source.contains("if (!window.__rearcBoostPicker)"))
        XCTAssertTrue(source.contains("p.snapshotAt(12.0, 34.5)"))
        XCTAssertTrue(BoostEditorScripts.scanRepairCandidates.contains("return p.scanRepairCandidates(24)"))
        // Results are plain JSON values; only the page-message channel stringifies.
        XCTAssertFalse(BoostEditorScripts.scanRepairCandidates.contains("JSON.stringify(p."))
        XCTAssertTrue(BoostPickerScript.bridgeSource.contains("rearcPostMessage(JSON.stringify(obj))"))
    }

    func testSelectorIsEmbeddedAsAStringLiteral() throws {
        let selector = "a[title=\"x\"]\n'</script>"
        let literal = BoostEditorScripts.jsLiteral(selector)
        let decoded = try JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed) as? String
        XCTAssertEqual(decoded, selector)
        XCTAssertTrue(BoostEditorScripts.highlight(selector: selector).contains(literal))
    }

    func testLiveStylesheetEmbedsCompiledRules() {
        XCTAssertTrue(BoostEditorScripts.liveStylesheet("")?.contains("var rules = [];") == true)
        let source = BoostEditorScripts.liveStylesheet("body { color: red; }")
        XCTAssertNotNil(source)
        XCTAssertTrue(source?.contains("color: red") == true || source?.contains("color:red") == true)
    }
}
