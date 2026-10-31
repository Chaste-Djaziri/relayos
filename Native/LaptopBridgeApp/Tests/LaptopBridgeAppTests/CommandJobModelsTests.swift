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
}
