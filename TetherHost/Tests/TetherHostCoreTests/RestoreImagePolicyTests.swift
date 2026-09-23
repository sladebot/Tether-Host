import Foundation
import XCTest
@testable import TetherHostCore

final class RestoreImagePolicyTests: XCTestCase {
    func testMatchingReleaseOnlyUpToHostVersion() {
        for (host, accepted, rejected) in [
            ("14.0", "14.0", "14.1"),
            ("14.6.1", "14.6", "15.0"),
            ("15.0", "15.0", "15.1"),
            ("15.6.1", "15.6", "26.0"),
            ("26.2", "26.2", "26.6.2"),
            ("27.0", "27.0", "27.1")
        ] {
            let hostVersion = try! XCTUnwrap(RestoreImagePolicy.parseVersion(host))
            XCTAssertTrue(RestoreImagePolicy.isEligible(try! XCTUnwrap(RestoreImagePolicy.parseVersion(accepted)), for: hostVersion))
            XCTAssertFalse(RestoreImagePolicy.isEligible(try! XCTUnwrap(RestoreImagePolicy.parseVersion(rejected)), for: hostVersion))
        }
        let host = try! XCTUnwrap(RestoreImagePolicy.parseVersion("26.2"))
        XCTAssertTrue(RestoreImagePolicy.isEligible(try! XCTUnwrap(RestoreImagePolicy.parseVersion("14.6.1")), for: host))
        XCTAssertTrue(RestoreImagePolicy.isEligible(try! XCTUnwrap(RestoreImagePolicy.parseVersion("15.6.1")), for: host))
        XCTAssertFalse(RestoreImagePolicy.isEligible(try! XCTUnwrap(RestoreImagePolicy.parseVersion("13.7")), for: host))
    }

    func testMalformedVersionsCannotEnterCandidateList() {
        for version in ["", "14", "14.", "14..0", "14.0.0.1", "14.-1", "-14.0", "14.one", "0.0"] {
            XCTAssertNil(RestoreImagePolicy.parseVersion(version), version)
        }
    }

    func testDefaultFollowsCurrentHostAndPreservesOlderChoice() {
        let versions = ["14.6.1", "15.6.1", "26.2", "26.6.2", "27.0"]
            .compactMap(RestoreImagePolicy.parseVersion)
        let host = try! XCTUnwrap(RestoreImagePolicy.parseVersion("26.2"))
        let defaultVersion = RestoreImagePolicy.preferredVersion(from: versions, for: host)
        XCTAssertEqual(defaultVersion?.majorVersion, 26)
        XCTAssertEqual(defaultVersion?.minorVersion, 2)

        let older = try! XCTUnwrap(RestoreImagePolicy.parseVersion("15.6.1"))
        let retained = RestoreImagePolicy.preferredVersion(from: versions, for: host, retaining: older)
        XCTAssertEqual(retained?.majorVersion, 15)
        XCTAssertEqual(retained?.minorVersion, 6)
        XCTAssertEqual(retained?.patchVersion, 1)

        let unavailable = try! XCTUnwrap(RestoreImagePolicy.parseVersion("26.6.2"))
        let fallback = RestoreImagePolicy.preferredVersion(from: versions, for: host, retaining: unavailable)
        XCTAssertEqual(fallback?.majorVersion, 26)
        XCTAssertEqual(fallback?.minorVersion, 2)
    }

    func testOnlyAppleHTTPSIPSWOriginsAreDownloadable() {
        XCTAssertTrue(RestoreImagePolicy.isAppleImageURL(URL(string:
            "https://updates.cdn-apple.com/2024SummerFCS/fullrestores/UniversalMac_14.6.1_23G93_Restore.ipsw")))
        for address in [
            "http://updates.cdn-apple.com/image.ipsw",
            "https://updates.cdn-apple.com.evil.example/image.ipsw",
            "https://example.com/image.ipsw",
            "https://updates.cdn-apple.com:8443/image.ipsw",
            "https://updates.cdn-apple.com/image.zip"
        ] {
            XCTAssertFalse(RestoreImagePolicy.isAppleImageURL(URL(string: address)), address)
        }
    }
}
