//
//  ControlCenterSupport.swift
//  PingWarden
//
//  Centralized capability checks for Control Center widget mode.
//

import Foundation
import Security
#if canImport(WidgetKit)
import WidgetKit
#endif

enum ControlCenterSupport {
    /// Must match `PingWardenControlKind.pingProtection` in the widget target.
    static let pingProtectionControlKind = "PingWardenWidget"

    /// Ask Control Center to re-render the Ping Protection toggle. The main
    /// app must call this whenever the monitoring intent or effective state
    /// changes — the widget only re-reads shared defaults when reloaded, so
    /// without this a menu-bar or Game Mode toggle leaves the Control Center
    /// toggle displaying stale state indefinitely.
    static func reloadPingProtectionControl() {
        #if canImport(WidgetKit)
        if #available(macOS 26.0, *) {
            ControlCenter.shared.reloadControls(ofKind: pingProtectionControlKind)
        }
        #endif
    }

    enum Availability: Equatable {
        case available
        case unsupportedOS
        case missingWidgetExtension
        case unsignedOrUntrusted

        var isAvailable: Bool {
            self == .available
        }

        var statusText: String {
            switch self {
            case .available:
                return "Ready"
            case .unsupportedOS, .missingWidgetExtension, .unsignedOrUntrusted:
                return "Unavailable"
            }
        }

        var detailText: String {
            switch self {
            case .available:
                return "Use the Control Center toggle and keep Ping Warden in the Dock"
            case .unsupportedOS:
                return "Requires macOS 26 or newer"
            case .missingWidgetExtension:
                return "Widget extension is missing from the app bundle"
            case .unsignedOrUntrusted:
                return "Requires Developer ID-signed app"
            }
        }

        var footerText: String {
            switch self {
            case .available:
                return "Add the Ping Protection control in System Settings → Control Center. This setting only hides the menu bar icon."
            case .unsupportedOS:
                return "Control Center widgets in Ping Warden require macOS 26 or newer."
            case .missingWidgetExtension:
                return "The Ping Warden widget extension was not found in this app bundle. Reinstall Ping Warden from a signed release."
            case .unsignedOrUntrusted:
                return "Control Center widgets require the app to be signed with Ping Warden's Developer ID certificate."
            }
        }
    }

    static func isAvailableForCurrentApp() -> Bool {
        availabilityForCurrentApp().isAvailable
    }

    static func availabilityForCurrentApp() -> Availability {
        guard #available(macOS 26.0, *) else {
            return .unsupportedOS
        }

        guard let widgetURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent("PingWardenWidget.appex"),
              let widgetBundle = Bundle(url: widgetURL),
              let extensionInfo = widgetBundle.infoDictionary?["NSExtension"] as? [String: Any],
              extensionInfo["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension" else {
            return .missingWidgetExtension
        }

        guard let bundleURL = Bundle.main.bundleURL as CFURL? else {
            return .unsignedOrUntrusted
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return .unsignedOrUntrusted
        }

        var requirement: SecRequirement?
        let requirementString = "anchor apple generic and certificate leaf[subject.OU] = \"PV3W52NDZ3\""
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else {
            return .unsignedOrUntrusted
        }

        return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess ? .available : .unsignedOrUntrusted
    }
}
