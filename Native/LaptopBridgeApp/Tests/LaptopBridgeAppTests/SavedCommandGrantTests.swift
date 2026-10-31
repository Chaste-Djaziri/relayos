// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/SavedCommandGrantTests.swift
import Foundation
import XCTest
@testable import LaptopBridgeApp

final class SavedCommandGrantTests: XCTestCase {
    func testDecodePrefixAndDisplay() throws {
        let json = """
        [{"token":"grant-1","project_root":"/tmp/project",
          "working_directory":"/tmp/project","executable":"/usr/bin/git",
          "grant_type":"always","family_key":null,"scope_prefix":["git","commit"],
          "created_at":100.0,"expires_at":null}]
        """
        let grants = try JSONDecoder().decode([SavedCommandGrant].self, from: Data(json.utf8))
        let grant = try XCTUnwrap(grants.first)
        XCTAssertEqual(grant.id, "grant-1")
        XCTAssertEqual(grant.scopeTitle, "git commit")
        XCTAssertEqual(grant.durationTitle, "Always allowed")
        XCTAssertTrue(grant.scopeDetails.contains("may vary"))
        XCTAssertFalse(grant.isExpired())
    }

    func testLegacyFamilyAndExpiredExactScope() throws {
        let json = """
        [{"token":"a","project_root":"/tmp","working_directory":"/tmp",
          "executable":"/usr/bin/git","grant_type":"session",
          "family_key":"git:add","scope_prefix":null,"created_at":1,"expires_at":10},
         {"token":"b","project_root":"/tmp","working_directory":"/tmp",
          "executable":"/usr/bin/git","grant_type":"always",
          "family_key":null,"scope_prefix":null,"created_at":1,"expires_at":null}]
        """
        let grants = try JSONDecoder().decode([SavedCommandGrant].self, from: Data(json.utf8))
        XCTAssertEqual(grants[0].scopeTitle, "git add")
        XCTAssertEqual(grants[0].durationTitle, "For coding session")
        XCTAssertTrue(grants[0].isExpired(at: Date(timeIntervalSince1970: 11)))
        XCTAssertEqual(grants[1].scopeTitle, "Exact command")
        XCTAssertTrue(grants[1].scopeDetails.contains("not retained"))
    }
}
