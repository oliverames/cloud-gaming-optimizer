//
//  PingWardenWidget.swift
//  PingWardenWidget
//
//  Control Center widget for toggling AWDL blocking.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

import SwiftUI
import WidgetKit
import AppIntents

enum PingWardenControlKind {
    static let pingProtection = "PingWardenWidget"
}

/// Control Widget for managing AWDL interface from Control Center
/// Shows current state and allows toggling AWDL monitoring on/off
@main
struct PingWardenWidget: ControlWidget {
    static let kind: String = PingWardenControlKind.pingProtection

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            // Display user *intent*, which is exactly what the toggle intent
            // sets. Mixing in the effective runtime state made the toggle
            // snap back to On after a disable (effective stayed true until
            // the app processed the change) and made
            // ToggleAWDLMonitoringIntent flip a different state than shown.
            let isOn = PingWardenPreferences.shared.isMonitoringEnabled
            ControlWidgetToggle(isOn: isOn, action: SetPingProtectionIntent()) {
                Label(
                    isOn ? "Protection On" : "Protection Off",
                    systemImage: isOn ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right"
                )
            } valueLabel: { isOn in
                Text(isOn ? "On" : "Off")
            }
            .tint(.blue)
        }
        .displayName("Ping Protection")
        .description("Toggle Ping Protection to reduce latency spikes")
    }
}
