import Foundation

enum SettingsTab: String, Hashable, CaseIterable {
    case general = "General"
    case storage = "Storage"
    case appearance = "Appearance"
    case security = "Security"
    case systemPermissions = "System permissions"
    case approvals = "Approvals"
    case activity = "Activity"
    case connections = "Connections"
    case ngrok = "ngrok transport"
    case tools = "Tools & permissions"
    case commandPermissions = "Command permissions"
    case terminalJobs = "Terminal jobs"
}

