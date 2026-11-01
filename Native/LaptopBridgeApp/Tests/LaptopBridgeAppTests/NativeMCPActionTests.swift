// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/NativeMCPActionTests.swift
import Foundation
import XCTest
@testable import LaptopBridgeApp

final class NativeMCPActionTests: XCTestCase {
    var base: URL!
    var store: NativeMCPDevelopmentStore!
    var actions: NativeMCPActions!
    var inbox: NativeMCPApprovalStore!
    var session: String!
    var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NativeMCPDevelopmentStore(directory: base.appendingPathComponent("native-test"))
        let auth = try store.bootstrap()
        session = try store.grantProjectFolder(root)
        inbox = NativeMCPApprovalStore(databaseURL: store.databaseURL)
        actions = NativeMCPActions(authorization: auth, approvals: inbox)
    }

    override func tearDownWithError() throws {
        actions.jobs.shutdown()
        try? FileManager.default.removeItem(at: base)
    }

    private func args(path: String = "hello.txt", content: String = "hello") -> [String: Any] {
        ["session_id": session!, "project_root": root.path, "path": path, "content": content]
    }

    private func requestID(_ proposed: [String: Any]) throws -> String {
        try XCTUnwrap(proposed["request_id"] as? String)
    }

    func testNativeApprovalAuditPersistsDecisions() throws {
        let id = try requestID(actions.propose(kind: "write_project_file", args: args()))
        try inbox.decide(id: id, decision: .deny)
        let events = try inbox.activity().filter { $0["request_id"] == id }
        XCTAssertEqual(events.map { $0["event"] }.reversed(), ["pending", "deny"])
    }

    func testWriteRequiresLocalApprovalAndDeniesReplay() throws {
        let input = args()
        let proposal = try actions.propose(kind: "write_project_file", args: input)
        let id = try requestID(proposal)
        XCTAssertEqual(try inbox.pending().count, 1)
        XCTAssertThrowsError(try actions.execute(kind: "write_project_file", args: input, requestID: id))
        try inbox.decide(id: id, decision: .once)
        XCTAssertThrowsError(try actions.execute(
            kind: "write_project_file", args: args(content: "tampered"), requestID: id))
        // Mismatched attempt consumes the single-use approval, preventing
        // attacker-controlled substitution or subsequent replay.
        XCTAssertThrowsError(try actions.execute(kind: "write_project_file", args: input, requestID: id))

        let second = try requestID(actions.propose(kind: "write_project_file", args: input))
        try inbox.decide(id: second, decision: .once)
        let result = try actions.execute(kind: "write_project_file", args: input, requestID: second)
        XCTAssertEqual(result["written"] as? Bool, true)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("hello.txt"), encoding: .utf8), "hello")
        XCTAssertThrowsError(try actions.execute(kind: "write_project_file", args: input, requestID: second))
    }

    func testPatchRequiresExactMatchAndSessionScope() throws {
        try "old value".write(to: root.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let input: [String: Any] = [
            "session_id": session!, "project_root": root.path, "path": "hello.txt",
            "search": "old", "replacement": "new"
        ]
        let id = try requestID(actions.propose(kind: "apply_project_patch", args: input))
        try inbox.decide(id: id, decision: .once)
        _ = try actions.execute(kind: "apply_project_patch", args: input, requestID: id)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("hello.txt"), encoding: .utf8), "new value")
        XCTAssertThrowsError(try actions.propose(kind: "write_project_file", args: args(path: "../escape.txt")))
        try store.revokeSession(session)
        XCTAssertThrowsError(try actions.propose(kind: "apply_project_patch", args: input))
    }

    func testNativeMCPHTTPActionProposalApprovalAndWrite() throws {
        let auth = NativeMCPAuthorization(databaseURL: store.databaseURL)
        let token = try String(contentsOf: store.credentialURL, encoding: .utf8)
        let http = NativeMCPHTTP(authorization: auth, port: 18765, actions: actions)
        let headers = ["host": "127.0.0.1:18765", "authorization": "Bearer \(token)"]
        func invoke(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": name, "arguments": args]
            ] as [String: Any])
            let result = http.handle(method: "POST", path: "/mcp", headers: headers, body: data)
            XCTAssertEqual(result.status, 200)
            let rpc = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
            let contents = try XCTUnwrap((rpc["result"] as? [String: Any])?["content"] as? [[String: Any]])
            let string = try XCTUnwrap(contents.first?["text"] as? String)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
        }
        let arguments = args(content: "written through native HTTP")
        let proposed = try invoke("propose_native_action",
                                  ["kind": "write_project_file", "arguments": arguments])
        let id = try XCTUnwrap(proposed["request_id"] as? String)
        try inbox.decide(id: id, decision: .once)
        let done = try invoke("execute_native_action",
                              ["kind": "write_project_file", "arguments": arguments, "request_id": id])
        XCTAssertEqual(done["written"] as? Bool, true)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("hello.txt"),
                                  encoding: .utf8), "written through native HTTP")
    }

    func testScreenAndGuidanceAreBoundToLocalApproval() throws {
        let base: [String: Any] = ["session_id": session!, "project_root": root.path]
        XCTAssertThrowsError(try actions.propose(kind: "show_guidance", args:
            base.merging(["message": "Look here", "x": 3.5, "y": 0.5] as [String: Any]) { _, new in new }))
        XCTAssertThrowsError(try actions.propose(kind: "start_guidance_session", args:
            base.merging(["max_duration_seconds": 9999] as [String: Any]) { _, new in new }))
        let request = try requestID(actions.propose(kind: "screen_snapshot", args: base))
        XCTAssertThrowsError(try actions.execute(kind: "screen_snapshot", args: base, requestID: request))
        try inbox.decide(id: request, decision: .deny)
        XCTAssertThrowsError(try actions.execute(kind: "screen_snapshot", args: base, requestID: request))
        let pending = try requestID(actions.propose(kind: "start_guidance_session",
                                                    args: base.merging(["max_duration_seconds": 120] as [String: Any]) { _, new in new }))
        XCTAssertTrue(try inbox.pending().contains { $0.id == pending })
        // Do not issue an OS screenshot or display overlay from this unit test.
    }

    func testDeniedCommandDoesNotRunAndApprovedJobIsScoped() throws {
        let command: [String: Any] = [
            "session_id": session!, "project_root": root.path, "cwd": ".",
            "argv": ["/usr/bin/true"]
        ]
        let denied = try requestID(actions.propose(kind: "start_project_command_job", args: command))
        try inbox.decide(id: denied, decision: .deny)
        XCTAssertThrowsError(try actions.execute(kind: "start_project_command_job", args: command, requestID: denied))
        let approved = try requestID(actions.propose(kind: "start_project_command_job", args: command))
        try inbox.decide(id: approved, decision: .once)
        let result = try actions.execute(kind: "start_project_command_job", args: command, requestID: approved)
        let jobID = try XCTUnwrap(result["job_id"] as? String)
        let status = try actions.readJob(["session_id": session!, "project_root": root.path, "job_id": jobID])
        XCTAssertEqual(status["job_id"] as? String, jobID)
        XCTAssertThrowsError(try actions.readJob([
            "session_id": UUID().uuidString, "project_root": root.path, "job_id": jobID
        ]))
    }
}
