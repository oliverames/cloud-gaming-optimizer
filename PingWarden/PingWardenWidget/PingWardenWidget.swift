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

/// Control Widget for managing AWDL interface from Control Center
/// Shows current state and allows toggling AWDL monitoring on/off
@main
struct PingWardenWidget: ControlWidget {
    static let kind: String = "PingWardenWidget"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleAWDLMonitoringIntent()) {
                let isOn = PingWardenPreferences.shared.effectiveMonitoringEnabled || PingWardenPreferences.shared.isMonitoringEnabled
                Label(
                    isOn ? "Protection On" : "Protection Off",
                    systemImage: isOn ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right"
                )
            }
            .tint(.blue)
        }
        .displayName("Ping Protection")
        .description("Toggle Ping Protection to reduce latency spikes")
    }
}
