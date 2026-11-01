// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/NativeMCPSystem.swift
import Foundation
import Darwin

/// Native, read-only system information for the Swift MCP runtime.
/// Optional metrics are null rather than fabricated when unavailable.
struct NativeMCPSystem {
    enum SystemError: Error { case processFailed, malformedOutput }

    func status() -> [String: Any] {
        var name = [CChar](repeating: 0, count: 256)
        let host = gethostname(&name, name.count) == 0
            ? String(cString: name) : "unknown"
        return [
            "hostname": host,
            "os": "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
            "cpu_percent": NSNull(),
            "ram_used_percent": NSNull(),
            "battery_percent": NSNull(),
            "battery_charging": NSNull()
        ]
    }

    func listProcesses(limit: Int = 50, sortBy: String = "cpu") throws -> [[String: Any]] {
        guard (1...200).contains(limit), ["cpu", "memory"].contains(sortBy) else {
            throw SystemError.malformedOutput
        }
        // Fixed executable and fixed arguments: clients cannot inject shell
        // syntax, select an executable, or cause a terminal command to run.
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/ps")
        command.arguments = ["-axo", "pid=,pcpu=,pmem=,rss=,comm="]
        let pipe = Pipe()
        command.standardOutput = pipe
        command.standardError = Pipe()
        try command.run()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        command.waitUntilExit()
        guard command.terminationStatus == 0, data.count < 2_000_000,
              let output = String(data: data, encoding: .utf8) else {
            throw SystemError.processFailed
        }
        let items: [[String: Any]] = output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 4, omittingEmptySubsequences: true) {
                $0 == " " || $0 == "\t"
            }
            guard fields.count == 5,
                  let pid = Int(fields[0]),
                  let cpu = Double(fields[1]),
                  let memory = Double(fields[2]),
                  let residentKB = Double(fields[3]),
                  cpu.isFinite, memory.isFinite, residentKB.isFinite else { return nil }
            return [
                "pid": pid,
                "name": String(fields[4]),
                "cpu_percent": cpu,
                "memory_percent": memory,
                "memory_mb": (residentKB / 1024 * 10).rounded() / 10
            ]
        }
        let sorted = items.sorted { lhs, rhs in
            let key = sortBy == "memory" ? "memory_percent" : "cpu_percent"
            let a = lhs[key] as? Double ?? 0
            let b = rhs[key] as? Double ?? 0
            if a != b { return a > b }
            return (lhs["pid"] as? Int ?? 0) < (rhs["pid"] as? Int ?? 0)
        }
        return Array(sorted.prefix(limit))
    }
}
