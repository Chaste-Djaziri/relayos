// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/SystemPermissionAccess.swift
import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import UserNotifications

enum SystemPermissionKind: String, CaseIterable, Identifiable {
    case screenRecording, fullDiskAccess, accessibility, notifications
    case automation, appManagement, filesAndFolders
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "Screen & System Audio Recording"
        case .fullDiskAccess: "Full Disk Access"
        case .accessibility: "Accessibility"
        case .notifications: "Notifications"
        case .automation: "Automation"
        case .appManagement: "App Management"
        case .filesAndFolders: "Files & Folders"
        }
    }
    var icon: String {
        switch self {
        case .screenRecording: "video"
        case .fullDiskAccess: "externaldrive"
        case .accessibility: "hand.raised"
        case .notifications: "bell"
        case .automation: "applescript"
        case .appManagement: "app.badge.checkmark"
        case .filesAndFolders: "folder"
        }
    }
    var settingsAnchor: String {
        switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .accessibility: "Privacy_Accessibility"
        case .notifications: "Privacy"
        case .automation: "Privacy_Automation"
        case .appManagement: "Privacy_AppBundles"
        case .filesAndFolders: "Privacy_FilesAndFolders"
        }
    }
    var explanation: String {
        switch self {
        case .screenRecording: "Optional. Allows locally approved screen inspection and capture."
        case .fullDiskAccess: "Highly sensitive. Only grant for a specific task that cannot use a selected folder."
        case .accessibility: "Optional. Needed for user-approved pointer and keyboard control."
        case .notifications: "Shows incoming approval requests without revealing command contents."
        case .automation: "macOS grants Apple Events access separately for each target app."
        case .appManagement: "macOS controls which apps may modify or manage other installed apps."
        case .filesAndFolders: "macOS prompts for protected folders when needed; workspace grants remain separate."
        }
    }
    var instructions: String {
        switch self {
        case .screenRecording: "Select RelayOS if listed, or use the Add (+) button and choose RelayOS.app."
        case .fullDiskAccess: "Only if necessary: use Add (+) to choose RelayOS.app, then enable the switch."
        case .accessibility: "Use Add (+) to choose RelayOS.app, then enable it for approved computer control."
        case .notifications: "Find RelayOS in Notifications and enable alerts if you want approval banners."
        case .automation: "Permissions appear after RelayOS requests access to a particular scriptable app."
        case .appManagement: "Review the applications shown here. macOS determines when a request is needed."
        case .filesAndFolders: "Grant only requested folders. Prefer the normal file picker and project-scoped grants."
        }
    }
    var supportsAppDrag: Bool {
        switch self {
        case .screenRecording, .fullDiskAccess, .accessibility: true
        default: false
        }
    }
}

enum PermissionObservation: Equatable {
    case granted, notGranted, manual, pending

    var label: String {
        switch self {
        case .granted: "Granted"
        case .notGranted: "Not granted"
        case .manual: "Check in Settings"
        case .pending: "Checking"
        }
    }
}

// TCC exposes no general-purpose API to read Full Disk Access, Automation,
// App Management, or Files & Folders grants. Never infer them from arbitrary
// private-directory reads or report a fictitious "Ready" state.
@MainActor
final class SystemPermissionAccess: ObservableObject {
    @Published private(set) var status: [SystemPermissionKind: PermissionObservation] = [:]

    init() { refresh() }

    func observation(for kind: SystemPermissionKind) -> PermissionObservation {
        status[kind] ?? .manual
    }

    func refresh() {
        status[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        status[.accessibility] = AXIsProcessTrusted() ? .granted : .notGranted
        for kind in SystemPermissionKind.allCases where kind != .screenRecording
                && kind != .accessibility && kind != .notifications {
            status[kind] = .manual
        }
        status[.notifications] = .pending
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let granted = settings.authorizationStatus == .authorized ||
                settings.authorizationStatus == .provisional
            Task { @MainActor [weak self] in
                self?.status[.notifications] = granted ? .granted : .notGranted
            }
        }
    }

    func openGuide(for kind: SystemPermissionKind) {
        PermissionGuidePanel.shared.present(for: kind)
        let anchor = kind.settingsAnchor
        let urlText: String
        if kind == .notifications {
            urlText = "x-apple.systempreferences:com.apple.preference.notifications"
        } else {
            urlText = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        }
        if let url = URL(string: urlText) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}
