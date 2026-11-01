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

    func testDecodesFileWriteAndCommandActivityDetails() throws {
        let writeJson = """
        {"id":15,"recorded_at":300,"kind":"write_project_file","target":"/repo:src/app.py",
         "decision":"executed","exit_code":0,"duration_ms":0,
         "detail_json":"{\\"path\\":\\"src/app.py\\",\\"is_new\\":false,\\"diff\\":\\"--- a/src/app.py\\\\n+++ b/src/app.py\\\\n@@ -1 +1 @@\\\\n-old\\\\n+new\\\\n\\",\\"lines_added\\":1,\\"lines_removed\\":1,\\"bytes_written\\":4}"}
        """
        let writeEntry = try JSONDecoder().decode(ApprovalActivityEntry.self, from: Data(writeJson.utf8))
        XCTAssertEqual(writeEntry.summaryTitle, "Edited src/app.py")
        XCTAssertEqual(writeEntry.details?.linesAdded, 1)
        XCTAssertEqual(writeEntry.details?.linesRemoved, 1)
        XCTAssertEqual(writeEntry.details?.path, "src/app.py")
        XCTAssertTrue(writeEntry.details?.diff?.contains("+new") == true)

        let cmdJson = """
        {"id":16,"recorded_at":310,"kind":"run_project_command","target":"/repo:npm test",
         "decision":"executed","exit_code":0,"duration_ms":1450,
         "detail_json":"{\\"argv\\":[\\"npm\\",\\"test\\"],\\"command\\":\\"npm test\\",\\"working_directory\\":\\"/repo\\",\\"stdout\\":\\"Tests passed\\\\n\\",\\"stderr\\":\\"\\"}"}
        """
        let cmdEntry = try JSONDecoder().decode(ApprovalActivityEntry.self, from: Data(cmdJson.utf8))
        XCTAssertEqual(cmdEntry.summaryTitle, "Ran npm test")
        XCTAssertEqual(cmdEntry.details?.command, "npm test")
        XCTAssertEqual(cmdEntry.details?.stdout, "Tests passed\n")
        XCTAssertEqual(cmdEntry.formattedDuration, "1.45 s")
    }
}
