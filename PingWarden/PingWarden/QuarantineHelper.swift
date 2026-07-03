//
//  QuarantineHelper.swift
//  PingWarden
//
//  Helper to check if the app was downloaded and needs quarantine removal.
//  Provides user guidance for Gatekeeper issues.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

import Foundation
import AppKit

/// Utility to detect and help resolve Gatekeeper quarantine issues
struct QuarantineHelper {
    
    /// Check if the app bundle has quarantine attributes
    static func isQuarantined() -> Bool {
        guard let bundlePath = Bundle.main.bundlePath as NSString?,
              let path = bundlePath.utf8String else {
            return false
        }

        // Try to get quarantine xattr
        let attrName = "com.apple.quarantine"
        
        // Get size of attribute
        let size = Darwin.getxattr(path, attrName, nil, 0, 0, 0)
        
        // If size > 0, quarantine attribute exists
        return size > 0
    }
    
    /// Check if the app is code signed (not ad-hoc)
    static func isProperlyCodeSigned() -> Bool {
        guard let bundleURL = Bundle.main.bundleURL as CFURL? else { return false }
        
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }
        
        // Check for valid signature (not ad-hoc)
        var requirement: SecRequirement?
        let requirementString = "anchor apple generic and certificate leaf[subject.OU] exists"
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else { return false }
        
        return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
    }
    
    /// Show helpful dialog if app is quarantined
    static func showQuarantineHelpIfNeeded() {
        // Run the checks off the main thread: SecStaticCodeCheckValidity
        // hashes the whole bundle (including Sparkle.framework) on the
        // quarantined first-run path, which would stall launch for seconds.
        DispatchQueue.global(qos: .utility).async {
            // Only show if quarantined and not properly signed (most users)
            guard isQuarantined() && !isProperlyCodeSigned() else {
                return
            }
            DispatchQueue.main.async {
                presentQuarantineHelpAlert()
            }
        }
    }

    private static func presentQuarantineHelpAlert() {
        // Build the remediation command from the actual bundle location —
        // the app may be running from ~/Downloads or a renamed bundle.
        let removalCommand = "xattr -cr \"\(Bundle.main.bundlePath)\""

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "First Time Setup"
            alert.informativeText = """
            Ping Warden is not code-signed by Apple, which is normal for open-source apps.
            
            If macOS prevented you from opening the app, you can fix this by:
            
            1. Opening Terminal
            2. Running this command:

            \(removalCommand)

            Then relaunch the app.
            
            This only needs to be done once!
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "I Already Did This")
            alert.addButton(withTitle: "More Info")
            
            let response = alert.runModal()
            
            switch response {
            case .alertFirstButtonReturn: // Copy Command
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(removalCommand, forType: .string)
                
                let confirmAlert = NSAlert()
                confirmAlert.messageText = "Command Copied!"
                confirmAlert.informativeText = "The command has been copied to your clipboard.\n\nPaste it into Terminal and press Enter."
                confirmAlert.alertStyle = .informational
                confirmAlert.addButton(withTitle: "OK")
                confirmAlert.runModal()
                
            case .alertThirdButtonReturn: // More Info
                if let url = URL(string: "https://github.com/oliverames/ping-warden#installation") {
                    NSWorkspace.shared.open(url)
                }
                
            default: // I Already Did This
                break
            }
        }
    }
    
    /// Attempt to remove quarantine attributes (requires admin privileges)
    /// This generally doesn't work from within the app itself, but worth trying
    static func attemptQuarantineRemoval() -> Bool {
        guard let bundlePath = Bundle.main.bundlePath as NSString?,
              let path = bundlePath.utf8String else {
            return false
        }

        let attrName = "com.apple.quarantine"
        
        // Try to remove quarantine attribute
        let result = Darwin.removexattr(path, attrName, 0)
        
        return result == 0
    }
}
