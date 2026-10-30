import XCTest
@testable import MovemberCore

final class UpdateChannelTests: XCTestCase {
    func testStableAndPrereleaseChannelsUseThisAppsPublicHTTPSFeeds() {
        XCTAssertEqual(UpdateChannel.feedURL(includePrereleases: false).absoluteString,
            "https://raw.githubusercontent.com/grahamgilbert/movembercam/main/appcast.xml")
        XCTAssertEqual(UpdateChannel.feedURL(includePrereleases: true).absoluteString,
            "https://raw.githubusercontent.com/grahamgilbert/movembercam/main/appcast-prerelease.xml")
    }

    func testAutomaticChecksUseOneHour() {
        XCTAssertEqual(UpdateChannel.checkInterval, 3600)
    }
}
