// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/DevelopmentRuntimeLocator.swift
import Foundation

/// Development-only fallback: installed apps must prefer bundled executable helpers.
enum DevelopmentRuntimeLocator {
    static func projectRoot() -> URL? {
        let sources = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            Bundle.main.executableURL?.deletingLastPathComponent()
        ].compactMap { $0 }
        return projectRoot(startingAt: sources, environment: ProcessInfo.processInfo.environment)
    }

    static func projectRoot(startingAt locations: [URL], environment: [String: String] = [:]) -> URL? {
        let override = environment["RELAYOS_DEV_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        for origin in [override].compactMap({ $0 }) + locations {
            var folder = origin.standardizedFileURL.resolvingSymlinksInPath()
            for _ in 0..<12 {
                let manifest = folder.appendingPathComponent("pyproject.toml")
                let package = folder.appendingPathComponent("src/laptop_bridge/__init__.py")
                if FileManager.default.fileExists(atPath: manifest.path)
                    && FileManager.default.fileExists(atPath: package.path) {
                    return folder
                }
                let parent = folder.deletingLastPathComponent()
                if parent.path == folder.path { break }
                folder = parent
            }
        }
        return nil
    }

    static func pythonExecutable() -> URL? {
        guard let root = projectRoot() else { return nil }
        let candidate = root.appendingPathComponent(".venv/bin/python")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }
}
