//
//  ControlCenterSupport.swift
//  PingWarden
//
//  Centralized capability checks for Control Center widget mode.
//

import Foundation
import Security

enum ControlCenterSupport {
    static func isAvailableForCurrentApp() -> Bool {
        guard #available(macOS 26.0, *) else {
            return false
        }

        guard let bundleURL = Bundle.main.bundleURL as CFURL? else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return false
        }

        var requirement: SecRequirement?
        let requirementString = "anchor apple generic and certificate leaf[subject.OU] = \"PV3W52NDZ3\""
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else {
            return false
        }

        return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
    }
}
