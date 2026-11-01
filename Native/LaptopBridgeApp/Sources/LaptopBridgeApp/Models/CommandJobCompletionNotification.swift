// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Models/CommandJobCompletionNotification.swift
import Foundation
import UserNotifications

enum CommandJobCompletionNotification {
    static let enabledKey = "relayos.jobCompletionNotificationsEnabled"

    /// Only a change from an active to a terminal state triggers a notification.
    /// Never include shell commands, paths, or process output in OS notifications.
    static func deliver(_ job: CommandJobEntry) {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        let content = UNMutableNotificationContent()
        switch job.status {
        case "completed":
            content.title = "RelayOS job completed"
        case "cancelled":
            content.title = "RelayOS job cancelled"
        case "timed_out":
            content.title = "RelayOS job timed out"
        case "interrupted":
            content.title = "RelayOS job interrupted"
        default:
            content.title = "RelayOS job finished"
        }
        content.body = job.exitCode.map { "Exit code \($0). Open RelayOS to view details." }
            ?? "Open RelayOS to review the result."
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "relayos-job-\(job.id)", content: content, trigger: nil
        ))
    }
}
