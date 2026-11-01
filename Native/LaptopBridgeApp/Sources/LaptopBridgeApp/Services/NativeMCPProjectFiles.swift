// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/NativeMCPProjectFiles.swift
import Foundation

/// Scoped, read-only project actions for the in-process native MCP migration.
/// Authorization comes from the same SQLite sessions as the Python service.
/// Explicitly not a replacement for per-command/per-write native approval yet.
struct NativeMCPProjectFiles {
    let authorization: NativeMCPAuthorization
    let maxReadBytes = 65_536

    enum AccessError: Error {
        case denied
        case notFound
        case notText
        case oversized
    }

    func validatedPath(sessionID: String, projectRoot: String,
                               relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard authorization.isProjectSessionActive(sessionID, root: root) else {
            throw AccessError.denied
        }
        // A project session grants exactly its root; never resolve paths beyond it.
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\0"),
              relativePath.utf8.count <= 4096 else { throw AccessError.denied }
        let resolved = root.appendingPathComponent(relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let parent = root.path == "/" ? "/" : root.path + "/"
        guard resolved.path == root.path || resolved.path.hasPrefix(parent) else {
            throw AccessError.denied
        }
        return resolved
    }

    func list(sessionID: String, projectRoot: String, folder: String) throws -> [[String: String]] {
        let url = try validatedPath(sessionID: sessionID, projectRoot: projectRoot, relativePath: folder)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AccessError.notFound
        }
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            .prefix(200).compactMap { entry in
                let actual = entry.standardizedFileURL.resolvingSymlinksInPath().path
                guard actual == root || actual.hasPrefix(root == "/" ? "/" : root + "/") else {
                    return nil
                }
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return ["name": entry.lastPathComponent,
                        "path": String(actual.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                        "type": isDir ? "directory" : "file"]
            }.sorted { ($0["name"] ?? "") < ($1["name"] ?? "") }
    }

    func read(sessionID: String, projectRoot: String, path: String) throws -> String {
        let url = try validatedPath(sessionID: sessionID, projectRoot: projectRoot, relativePath: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw AccessError.notFound }
        guard (values.fileSize ?? (maxReadBytes + 1)) <= maxReadBytes else { throw AccessError.oversized }
        let data = try Data(contentsOf: url)
        guard data.count <= maxReadBytes else { throw AccessError.oversized }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw AccessError.notText
        }
        return text
    }
}
