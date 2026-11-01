// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/Setup/FreshSetupView.swift
import SwiftUI
import AppKit

// First-run setup is optional-permission-first: no unnecessary Full Disk Access
// request and no requirement to grant screen or accessibility privileges.
struct FreshSetupView: View {
    @ObservedObject var model: BridgeModel
    @StateObject private var permissions: SystemPermissionAccess
    @AppStorage("relayos.onboarding.step") private var savedStep = 0
    @State private var tokenInput = ""
    @State private var previewCurrentStep = 0
    @Environment(\.colorScheme) private var colorScheme

    private var theme: ThemeColors { RelayOSTheme.colors(colorScheme) }
    private var step: Int { min(max(model.isPreview ? previewCurrentStep : savedStep, 0), 3) }

    init(model: BridgeModel, previewStep: Int = 0) {
        self.model = model
        _permissions = StateObject(wrappedValue: SystemPermissionAccess(preview: model.isPreview))
        _previewCurrentStep = State(initialValue: previewStep)
    }

    private func navigate(to value: Int) {
        if model.isPreview { previewCurrentStep = value }
        else { savedStep = value }
    }
    private let titles = ["Welcome to RelayOS", "Your local AI companion", "Choose optional permissions", "Connect your AI clients"]
    private let descriptions = [
        "A private, permission-gated bridge between your Mac and the AI tools you choose.",
        "Everything remains under your control. Review and approve each capability before it runs.",
        "Only enable permissions for features you intend to use. You can change them later.",
        "Set up a secure public MCP endpoint. Your ngrok token stays on your Mac."
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title2)
                Text("RelayOS").font(.headline)
                Spacer()
                Text("Setup \(step + 1) of 4").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { index in
                            Capsule()
                                .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.17))
                                .frame(height: 4)
                        }
                    }
                    Text(titles[step])
                        .font(.system(size: 31, weight: .semibold))
                    Text(descriptions[step])
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    switch step {
                    case 0: welcome
                    case 1: features
                    case 2: optionalPermissions
                    default: connectionSetup
                    }
                }
                .frame(maxWidth: 700, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                if step > 0 {
                    Button("Back") { navigate(to: step - 1) }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if step == 2 {
                    Button("Skip optional permissions") { navigate(to: 3) }
                        .buttonStyle(.bordered)
                }
                if step < 3 {
                    Button("Continue") { navigate(to: step + 1) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Save and connect") {
                        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !token.isEmpty else { return }
                        guard !model.isPreview else { return }
                        model.ngrokToken = token
                        model.ngrokDomainValue = ""
                        model.configureNgrok()
                        if model.endpoint != "Not configured" {
                            savedStep = 0
                            tokenInput = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPreview || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.windowBackground)
    }

    private var welcome: some View {
        SettingsCard(title: "Everything in one place") {
            featureRow("Approve before execution", detail: "Explicit local authorization and searchable activity", icon: "hand.raised")
            featureRow("Secure MCP connections", detail: "Use your approved clients through HTTPS", icon: "network")
            featureRow("Manage terminal jobs", detail: "See approved background jobs and their output", icon: "terminal", last: true)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Application preview")
                .font(.headline)
            HStack(spacing: 12) {
                previewCard(title: "Approvals", icon: "tray.full", subtitle: "Once · Session · Always · Deny")
                previewCard(title: "Connections", icon: "link", subtitle: "Scoped access to this Mac")
                previewCard(title: "Terminal jobs", icon: "terminal", subtitle: "Inspect · Cancel · Review")
            }
            Text("These cards are previews. They do not execute commands or grant access.")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var optionalPermissions: some View {
        SettingsCard(title: "Enable only when necessary") {
            optionalPermission(.screenRecording)
            optionalPermission(.accessibility)
            optionalPermission(.notifications, last: true)
        }
    }

    private var connectionSetup: some View {
        SettingsCard(title: "Secure connection") {
            VStack(alignment: .leading, spacing: 14) {
                Text("An ngrok account is required to establish the HTTPS bridge.")
                    .foregroundStyle(theme.textSecondary)
                    .font(.subheadline)
                Link("Get an ngrok authtoken", destination: URL(string: "https://dashboard.ngrok.com/get-started/your-authtoken")!)
                HStack {
                    SecureField("Paste ngrok authtoken", text: $tokenInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Paste") {
                        tokenInput = NSPasteboard.general.string(forType: .string)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    }
                }
                HStack(spacing: 12) {
                    Button("Install ngrok via Homebrew") { if !model.isPreview { model.installNgrok() } }
                        .disabled(model.isPreview)
                    if !model.ngrokInstallState.isEmpty {
                        Text(model.ngrokInstallState).font(.caption).foregroundStyle(theme.textSecondary)
                    }
                }
                Text("A stable free development domain is discovered automatically. After saving, check local and public health in General.")
                    .font(.caption).foregroundStyle(theme.textSecondary)
            }
            .padding(18)
        }
    }

    private func featureRow(_ title: String, detail: String, icon: String, last: Bool = false) -> some View {
        SettingsCardRow(title: title, subtitle: detail, showDivider: !last) {
            Image(systemName: icon).foregroundStyle(.secondary)
        }
    }
    private func optionalPermission(_ kind: SystemPermissionKind, last: Bool = false) -> some View {
        SettingsCardRow(title: kind.title, subtitle: kind.explanation, showDivider: !last) {
            Button("Set up") { if !model.isPreview { permissions.openGuide(for: kind) } }
                .disabled(model.isPreview)
                .buttonStyle(.bordered)
        }
    }
    private func previewCard(title: String, icon: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Image(systemName: icon).font(.system(size: 25))
                .frame(height: 32)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 140)
        .padding(14)
        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder))
    }
}

#if DEBUG
#Preview("Onboarding · Welcome") {
    FreshSetupView(model: BridgeModel.preview(), previewStep: 0)
        .frame(width: 1050, height: 740)
}
#Preview("Onboarding · Features") {
    FreshSetupView(model: BridgeModel.preview(), previewStep: 1)
        .frame(width: 1050, height: 740)
}
#Preview("Onboarding · Permissions") {
    FreshSetupView(model: BridgeModel.preview(), previewStep: 2)
        .frame(width: 1050, height: 740)
}
#Preview("Onboarding · Connect") {
    FreshSetupView(model: BridgeModel.preview(), previewStep: 3)
        .frame(width: 1050, height: 740)
}
#endif
