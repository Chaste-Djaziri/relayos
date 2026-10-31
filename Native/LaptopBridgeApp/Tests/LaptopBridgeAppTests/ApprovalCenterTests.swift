// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/ApprovalCenterTests.swift
import Foundation
import XCTest
@testable import LaptopBridgeApp

final class ApprovalCenterTests: XCTestCase {
    func testDecodesProjectCommandAndReusableScope() throws {
        let json = """
        {"request_id":"req-1","kind":"project_command","target":"/tmp/repo:/usr/bin/git",
         "argv":["git","commit","-m","test"],"created_at":100,"expires_at":400,
         "context":{"cwd":"/tmp/repo","scope_prefix":["git","commit"],"requested_grant":"once"}}
        """
        let item = try JSONDecoder().decode(ApprovalInboxItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.title, "git commit")
        XCTAssertEqual(item.context.cwd, "/tmp/repo")
        XCTAssertTrue(item.scopeDescription.contains("prefix"))
        XCTAssertFalse(item.isOAuth)
    }

    @MainActor
    func testArrivalTrackerSuppressesRepeatedPollNotifications() throws {
        let request = """
        {"request_id":"req-unique","kind":"project_command","target":"repo",
         "argv":["git","status"],"context":{},"created_at":100,"expires_at":400}
        """
        let item = try JSONDecoder().decode(ApprovalInboxItem.self, from: Data(request.utf8))
        let tracker = ApprovalArrivalTracker()
        XCTAssertEqual(tracker.newlyObserved([item]).count, 1)
        XCTAssertTrue(tracker.newlyObserved([item]).isEmpty)
        XCTAssertTrue(tracker.newlyObserved([]).isEmpty)
        XCTAssertTrue(tracker.newlyObserved([item]).isEmpty)
    }

    func testDecodesOAuthAndMetadataOnlyActivity() throws {
        let request = """
        {"request_id":"oauth-1","kind":"oauth_connection","target":"ChatGPT",
         "argv":[],"context":{"client_id":"client-1"},"created_at":100,"expires_at":400}
        """
        let item = try JSONDecoder().decode(ApprovalInboxItem.self, from: Data(request.utf8))
        XCTAssertTrue(item.isOAuth)
        XCTAssertEqual(item.title, "Connect ChatGPT")
        let activity = """
        {"id":12,"recorded_at":200,"kind":"project_command","target":"repo:git",
         "decision":"approved","exit_code":null,"duration_ms":null}
        """
        let record = try JSONDecoder().decode(ApprovalActivityEntry.self, from: Data(activity.utf8))
        XCTAssertEqual(record.id, 12)
        XCTAssertEqual(record.decision, "approved")
    }
}
