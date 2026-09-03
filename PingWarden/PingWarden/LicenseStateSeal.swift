//
//  LicenseStateSeal.swift
//  PingWarden
//
//  Seals the cached license gate state that lives in the shared App
//  Group defaults. The values themselves stay readable so the widget can
//  apply the same gate without keychain access, but every read verifies
//  an HMAC over the canonical payload (LicensePolicy.sealPayload) bound
//  to this Mac's hardware UUID. A hand-written `defaults write` or a
//  plist copied from a licensed Mac fails the check and the gate treats
//  the cache as absent until the next online verification.
//
//  The widget target carries an identical copy of the secret and the
//  HMAC in PingWardenWidgetLicenseGate.swift; change both together.
//

import CryptoKit
import Foundation
import IOKit

enum LicenseStateSeal {
    /// Build-time secret. The source is MIT, so this only raises the bar
    /// from a one-line `defaults write` to reading the code; anyone who
    /// goes that far can build the free source anyway.
    private static let secret = "pingwarden-license-seal-6f2c1a9e4b7d3c85e1f0a2b4c6d8e9f1-3579bdf02468ace1"

    /// Hex HMAC-SHA256 of a canonical payload.
    static func seal(_ payload: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison so a forged seal cannot be guessed byte
    /// by byte from timing.
    static func matches(_ stored: String?, payload: String) -> Bool {
        guard let stored, stored.count == 64 else { return false }
        let expected = seal(payload)
        var diff: UInt8 = 0
        for (a, b) in zip(Array(stored.utf8), Array(expected.utf8)) {
            diff |= a ^ b
        }
        return diff == 0 && stored.utf8.count == expected.utf8.count
    }

    /// The IOPlatformUUID of this Mac, or a fixed marker when IOKit
    /// cannot answer. The marker still seals, it just loses the
    /// per-device binding.
    static func deviceIdentifier() -> String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return "no-platform-expert" }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String, !value.isEmpty else {
            return "no-platform-uuid"
        }
        return value
    }
}
