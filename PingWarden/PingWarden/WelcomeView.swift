// Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
// Licensed under the MIT License.

import SwiftUI
import ServiceManagement

// MARK: - Welcome View

struct WelcomeView: View {
    static let defaultSize = NSSize(width: 540, height: 640)

    private enum SetupState: String, Equatable {
        case idle
        case waiting
        case complete
        case failed
    }

    let onSetup: (@escaping @MainActor @Sendable (Bool) -> Void) -> Void
    let onOpenDashboard: () -> Void
    let onDismiss: () -> Void

    var onOpenLicenseSettings: () -> Void = {}
    @ObservedObject private var license = LicenseManager.shared

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var setupState: SetupState = {
#if DEBUG
        let prefix = "--welcome-state="
        let value = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix(prefix) })?
            .dropFirst(prefix.count)
        return value.flatMap { SetupState(rawValue: String($0)) } ?? .idle
#else
        return .idle
#endif
    }()

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            welcomeContent
                            Spacer(minLength: 0)
                            setupFooter
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        welcomeContent
                    }

                    setupFooter
                }
            }
        }
        .frame(minWidth: 480, idealWidth: Self.defaultSize.width,
               minHeight: 560, idealHeight: Self.defaultSize.height)
        .background(.background)
    }

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)

                Text("Welcome to Ping Warden")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Stop the stutter when you cloud game on a Mac.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 28)
            .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 20) {
                WelcomeBenefitRow(
                    icon: "shield.lefthalf.filled",
                    title: "Stop Wi‑Fi lag spikes",
                    description: "Ping Protection stops AirDrop from grabbing the Wi‑Fi radio while you play GeForce NOW or any cloud game."
                )
                WelcomeBenefitRow(
                    icon: "waveform.path.ecg",
                    title: "Watch latency live",
                    description: "See your ping, jitter, and probe failures in the free dashboard."
                )
                WelcomeBenefitRow(
                    icon: "airplayaudio",
                    title: "Share when you need to",
                    description: "Pause protection to use AirDrop, AirPlay, and Handoff."
                )
            }
            .frame(maxWidth: 400)

            if !license.canEnableProtection {
                VStack(spacing: 6) {
                    Text("Ping Protection is a one-time $15 purchase.")
                        .font(.callout)
                    Button("Enter or Buy a License…", action: onOpenLicenseSettings)
                        .buttonStyle(.link)
                        .font(.callout)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)
            }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }

    private var setupFooter: some View {
        VStack(spacing: 14) {
            setupCallout
                .frame(maxWidth: 400)
            setupButtons
        }
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var setupCallout: some View {
        switch setupState {
        case .idle:
            Text("Setup asks for one approval in Login Items.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        case .waiting:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting for approval")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("In System Settings, allow Ping Warden under Login Items, then return here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        case .complete:
            Label(PingWardenMonitor.shared.isMonitoringActive
                ? "Setup complete. Ping Protection is on."
                : "Helper ready. Ping Protection is off.", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Label("Setup did not finish", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Approve Ping Warden in Login Items, then try again. If it is already allowed, open Advanced settings and run the helper test.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var setupButtons: some View {
        VStack(spacing: 12) {
            switch setupState {
            case .complete:
                openDashboardButton
            case .waiting:
                openLoginItemsButton
                laterButton
            case .idle, .failed:
                setupButton
                laterButton
            }
        }
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 240)
    }

    private var laterButton: some View {
        Button {
            onDismiss()
        } label: {
            Text("Not Now")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .keyboardShortcut(.cancelAction)
        .buttonStyle(.link)
        .font(.callout)
        .accessibilityIdentifier("welcome.later")
    }

    private var openLoginItemsButton: some View {
        Button {
            SMAppService.openSystemSettingsLoginItems()
        } label: {
            Text("Open Login Items")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("welcome.openLoginItems")
    }

    private var setupButton: some View {
        Button {
            setupState = .waiting
            onSetup { success in
                DispatchQueue.main.async {
                    setupState = success ? .complete : .failed
                }
            }
        } label: {
            Text(license.canEnableProtection ? "Turn On Ping Protection" : "Set Up Ping Warden")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("welcome.setup")
    }

    private var openDashboardButton: some View {
        Button {
            onOpenDashboard()
        } label: {
            Text("Open Dashboard")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("welcome.openDashboard")
    }
}

private struct WelcomeBenefitRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

