import XCTest
@testable import ReArc
@testable import SidebarModel

final class WKEngineProfileTests: XCTestCase {

    func testEngineConstructsWithProfileScopedContext() {
        let profileA = Profile.personalDefault()
        let profileB = Profile(name: "Work")
        let engineA = WKEngine(context: EngineProfileContext(profileID: profileA.id))
        let engineB = WKEngine(context: EngineProfileContext(profileID: profileB.id))
        XCTAssertEqual(engineA.profileContext.websiteDataStoreIdentifier, profileA.id)
        XCTAssertEqual(engineB.profileContext.websiteDataStoreIdentifier, profileB.id)
        XCTAssertNotEqual(
            engineA.profileContext.websiteDataStoreIdentifier,
            engineB.profileContext.websiteDataStoreIdentifier
        )
    }
}
