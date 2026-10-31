// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/ApprovalArrivalNotification.swift
import Foundation
import UserNotifications

enum ApprovalArrivalNotification {
    static let enabledKey = "relayos.approvalNotificationsEnabled"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    /// The caller provides only newly observed IDs, never ongoing pending IDs.
    /// No command arguments or OAuth callbacks are placed in OS notifications.
    static func deliver(_ request: ApprovalInboxItem) {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = request.isOAuth ? "RelayOS connection approval" : "RelayOS action approval"
        content.body = "A new approval request is waiting in RelayOS."
        let notification = UNNotificationRequest(
            identifier: "relayos-approval-\(request.requestID)",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(notification)
    }
}
