// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/CommandJobModelsTests.swift
import XCTest
import Foundation
@testable import LaptopBridgeApp

final class CommandJobModelsTests: XCTestCase {
    func testDecodeJobLifecycleAndCancellation() throws {
        let json = """
        [{"id":"job-1","session_id":"session-a","project_root":"/tmp/project",
          "working_directory":"/tmp/project","executable_name":"git",
          "status":"running","created_at":100,"finished_at":null,
          "exit_code":null,"output_bytes":42,"error_reason":null,
          "cancel_requested":0}]
        """
        let jobs = try JSONDecoder().decode([CommandJobEntry].self, from: Data(json.utf8))
        XCTAssertEqual(jobs[0].id, "job-1")
        XCTAssertTrue(jobs[0].active)
        XCTAssertEqual(jobs[0].executableName, "git")
    }

    func testDecodeIncrementalOutputAndOffsets() throws {
        let json = """
        {"stdout":"first","stderr":"","stdout_offset":5,"stderr_offset":0,
         "output_unavailable":false}
        """
        let result = try JSONDecoder().decode(CommandJobOutput.self, from: Data(json.utf8))
        XCTAssertEqual(result.stdoutOffset, 5)
        XCTAssertEqual(result.stdout, "first")
        XCTAssertFalse(result.outputUnavailable)
    }
    func testDecodeLocalControlJobList() throws {
        let json = """
        {"jobs":[{"id":"job-1","session_id":"session-a","project_root":"/tmp/project",
         "working_directory":"/tmp/project","executable_name":"swift",
         "status":"running","created_at":100,"finished_at":null,
         "exit_code":null,"output_bytes":42,"error_reason":null,"cancel_requested":0}]}
        """
        let payload = try JSONDecoder().decode(CommandJobListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(payload.jobs.count, 1)
        XCTAssertTrue(payload.jobs[0].active)
    }

    func testOutputRetentionAndStderrAreLabeled() {
        let text = CommandJobOutputFormatter.append(existing: "hello", stdout: " world",
                                                    stderr: "warning")
        XCTAssertTrue(text.contains("hello world"))
        XCTAssertTrue(text.contains("[stderr] warning"))
        let large = CommandJobOutputFormatter.append(
            existing: String(repeating: "x", count: 100_000), stdout: "", stderr: "")
        XCTAssertLessThan(large.count, 80_100)
        XCTAssertTrue(large.hasPrefix("… Earlier output omitted."))
    }

    func testOnlyCommandReportedPercentIsUsedForProgress() {
        XCTAssertNil(CommandJobProgress.percentage(in: "Compiling build 34 of 100"))
        XCTAssertEqual(CommandJobProgress.percentage(in: "Progress 23%"), 23)
        XCTAssertEqual(CommandJobProgress.percentage(in: "50%\r62.5%\r"), 62.5)
        XCTAssertEqual(CommandJobProgress.percentage(in: "download 100% finished"), 100)
        XCTAssertNil(CommandJobProgress.percentage(in: "120%"))
    }

    func testElapsedTimeDoesNotInventCompletionPercent() throws {
        let json = """
        {"id":"job-1","session_id":"session-a","project_root":"/tmp/project",
         "working_directory":"/tmp/project","executable_name":"git",
         "status":"completed","created_at":100,"finished_at":125,
         "exit_code":0,"output_bytes":42,"error_reason":null,"cancel_requested":0}
        """
        let job = try JSONDecoder().decode(CommandJobEntry.self, from: Data(json.utf8))
        XCTAssertEqual(CommandJobProgress.elapsed(job, at: Date(timeIntervalSince1970: 999)), 25)
        XCTAssertEqual(CommandJobProgress.elapsedLabel(job), "0m 25s")
        XCTAssertFalse(job.active)
    }

}
