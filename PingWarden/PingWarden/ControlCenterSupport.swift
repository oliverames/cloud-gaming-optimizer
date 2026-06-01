//
//  ControlCenterSupport.swift
//  PingWarden
//
//  Centralized capability checks for Control Center widget mode.
//

import Foundation
import Security

enum ControlCenterSupport {
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
                return "Use Control Center instead of the menu bar"
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
                return "To add the widget: System Settings → Control Center → scroll to Ping Warden"
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
