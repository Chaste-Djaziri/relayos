// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/Pages/StorageAuditPageView.swift
import SwiftUI
import AppKit
import Foundation

/// Local UI scan: only the folder picked by the person. It cannot delete or
/// modify files. The MCP equivalent always requires a separate Approve Once.
struct StorageAuditPageView: View {
    @State private var overview = StorageAuditService.volume()
    @State private var report: StorageAuditReport?
    @State private var scanning = false
    @State private var scanError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Mac storage") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Internal disk", systemImage: "internaldrive")
                        Spacer()
                        Button("Refresh") {
                            overview = StorageAuditService.volume()
                        }
                        .buttonStyle(.bordered)
                    }
                    if overview.total > 0 {
                        ProgressView(value: min(Double(overview.used) / Double(overview.total), 1))
                        HStack {
                            Text("\(format(overview.used)) used of \(format(overview.total))")
                            Spacer()
                            Text("\(format(overview.free)) available")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Storage information is unavailable.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }

            SettingsCard(title: "Read-only folder inspection") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose an exact folder to inspect. RelayOS identifies large files, generated caches, Git repositories and credential-file markers without reading file contents. Nothing is deleted.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button {
                            selectFolder()
                        } label: {
                            Label("Choose folder to scan", systemImage: "folder.badge.magnifyingglass")
                        }
                        .disabled(scanning)
                        if scanning {
                            ProgressView()
                            Text("Scanning metadata…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let scanError {
                        Text(scanError).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(14)
            }

            SettingsCard(title: "File and app management for ChatGPT") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Files, folders and installed apps", systemImage: "folder.badge.gearshape")
                        .font(.callout.weight(.semibold))
                    Text("ChatGPT can request a 15-minute file-manager session for a specific folder. Approve the request locally to allow file names, sizes, dates, search and application bundle details.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label("Changes always require separate approval", systemImage: "hand.raised")
                        .font(.callout.weight(.semibold))
                    Text("Moving to Trash, copying, moving, renaming and creating folders each require Approve Once. RelayOS protects system folders, credentials and its own active installation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label("Permanent deletion is separate", systemImage: "trash.slash")
                        .font(.callout.weight(.semibold))
                    Text("Empty Trash permanently removes ALL Finder Trash, including unrelated items. It requires a new approval and typing EMPTY TRASH on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("To use the new tools in ChatGPT, refresh the RelayOS plugin after updating the installed application. No automatic scans or cleanup will begin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }

            if let report {
                SettingsCard(title: "Folder results") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(report.root.lastPathComponent)
                            .font(.headline)
                        Text("\(format(report.bytes)) of scanned logical file data · \(report.fileCount) files · \(report.directoryCount) folders")
                            .font(.callout)
                        if report.partial {
                            Label("Partial results: size or time limit reached, or some folders were inaccessible.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                        Text("Credential-like filenames: \(report.secretMarkers). Local keys are never backed up or sent to GitHub automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                        Text("Largest folders / items")
                            .font(.subheadline.weight(.semibold))
                        ForEach(report.topItems.prefix(15)) { item in
                            storageRow(item.name, bytes: item.bytes)
                        }
                        if !report.cacheItems.isEmpty {
                            Divider()
                            Text("Potentially regenerable data — review first")
                                .font(.subheadline.weight(.semibold))
                            ForEach(report.cacheItems.prefix(12)) { item in
                                storageRow(item.name, bytes: item.bytes)
                            }
                        }
                        if !report.gitRepositories.isEmpty {
                            Divider()
                            Text("Git project directories detected")
                                .font(.subheadline.weight(.semibold))
                            ForEach(report.gitRepositories.prefix(15), id: \.self) { name in
                                Label(name, systemImage: "chevron.left.forwardslash.chevron.right")
                                    .font(.caption)
                            }
                            Text("The existence of a .git folder does not prove the project is saved on GitHub. Ask ChatGPT to check local changes and remote recoverability before cleanup.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("These are estimates of logical file sizes, not necessarily recoverable disk space. No deletion operation is available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                }
            }
        }
    }

    private func storageRow(_ name: String, bytes: Int64) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(format(bytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan read-only"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scanError = nil
        report = nil
        scanning = true
        Task.detached(priority: .utility) {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let result = StorageAuditService.scan(folder: url)
            await MainActor.run {
                report = result
                scanning = false
            }
        }
    }
}

private struct StorageAuditItem: Identifiable {
    let name: String
    let bytes: Int64
    var id: String { name }
}
private struct StorageAuditReport {
    let root: URL
    let bytes: Int64
    let fileCount: Int
    let directoryCount: Int
    let secretMarkers: Int
    let topItems: [StorageAuditItem]
    let cacheItems: [StorageAuditItem]
    let gitRepositories: [String]
    let partial: Bool
}
private enum StorageAuditService {
    private static let cacheNames: Set<String> = [
        "node_modules", ".next", ".nuxt", ".turbo", "__pycache__",
        ".pytest_cache", ".mypy_cache", "deriveddata", ".build", "build", "dist"
    ]
    private static let secretNames: Set<String> = [
        "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa",
        "credentials.json", "google-services.json", "google-services.plist",
        "service-account.json"
    ]

    static func volume() -> (total: Int64, used: Int64, free: Int64) {
        let path = FileManager.default.homeDirectoryForCurrentUser
        let values = try? path.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = Int64(values?.volumeAvailableCapacity ?? 0)
        return (total, max(0, total - free), free)
    }

    static func scan(folder: URL) -> StorageAuditReport {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let started = Date()
        let manager = FileManager.default
        var stack: [(URL, Int)] = [(root, 0)]
        var topSizes: [String: Int64] = [:]
        var cacheSizes: [String: Int64] = [:]
        var gitRoots: Set<String> = []
        var files = 0
        var dirs = 0
        var keys = 0
        var total: Int64 = 0
        var entries = 0
        var partial = false
        let properties: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

        while let (directory, depth) = stack.popLast() {
            if entries >= 25000 || Date().timeIntervalSince(started) > 10 {
                partial = true
                break
            }
            let children: [URL]
            do {
                children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(properties), options: [])
            } catch {
                partial = true
                continue
            }
            for child in children {
                if entries >= 25000 || Date().timeIntervalSince(started) > 10 {
                    partial = true
                    break
                }
                entries += 1
                guard let meta = try? child.resourceValues(forKeys: properties) else {
                    partial = true
                    continue
                }
                if meta.isSymbolicLink == true { continue }
                let relative = String(child.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let parts = relative.split(separator: "/").map(String.init)
                guard let first = parts.first else { continue }
                if meta.isDirectory == true {
                    dirs += 1
                    if child.lastPathComponent == ".git" {
                        gitRoots.insert(child.deletingLastPathComponent().path.replacingOccurrences(of: root.path, with: ""))
                    }
                    if depth < 29 { stack.append((child, depth + 1)) }
                    else { partial = true }
                    continue
                }
                files += 1
                let name = child.lastPathComponent.lowercased()
                if name == ".env" || name.hasPrefix(".env.") || secretNames.contains(name) ||
                    [".pem", ".p12", ".pfx", ".key", ".keystore"].contains(child.pathExtension.isEmpty ? "" : "." + child.pathExtension.lowercased()) {
                    keys += 1
                }
                let size = Int64(meta.fileSize ?? 0)
                total += size
                let firstName = (name == ".env" || name.hasPrefix(".env.") || secretNames.contains(name)) && parts.count == 1 ? "[sensitive]" : first
                topSizes[firstName, default: 0] += size
                for (index, component) in parts.dropLast().enumerated() where cacheNames.contains(component.lowercased()) {
                    cacheSizes[parts.prefix(index + 1).joined(separator: "/"), default: 0] += size
                    break
                }
            }
        }
        let top = topSizes.map { StorageAuditItem(name: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
        let caches = cacheSizes.map { StorageAuditItem(name: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
        return StorageAuditReport(root: root, bytes: total, fileCount: files, directoryCount: dirs,
                                  secretMarkers: keys, topItems: top, cacheItems: caches,
                                  gitRepositories: gitRoots.sorted(), partial: partial)
    }
}

#if DEBUG
#Preview("Storage audit") {
    ScrollView {
        StorageAuditPageView().padding(24)
    }
    .frame(width: 790, height: 700)
}
#endif
