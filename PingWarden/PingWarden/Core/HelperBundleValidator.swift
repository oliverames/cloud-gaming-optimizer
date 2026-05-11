//
//  HelperBundleValidator.swift
//  PingWarden
//
//  Validates that the helper daemon binary and plist are correctly bundled
//  in the app's `Contents/`. Pure-Foundation so it can be exercised by the
//  standalone test target.
//

import Foundation

enum HelperBundleValidator {
    enum ValidationFailure: Equatable {
        case binaryMissing(path: String)
        case plistMissing(path: String)
        case binaryNotExecutable(path: String)

        /// User-facing message; matches the strings the app previously surfaced.
        var userMessage: String {
            switch self {
            case .binaryMissing:
                return "Helper binary not found in app bundle.\n\nPlease reinstall the app."
            case .plistMissing:
                return "Helper configuration not found in app bundle.\n\nPlease reinstall the app."
            case .binaryNotExecutable:
                return "Helper binary is not executable.\n\nPlease reinstall the app."
            }
        }

        /// Diagnostic path useful for log lines.
        var path: String {
            switch self {
            case .binaryMissing(let path),
                 .plistMissing(let path),
                 .binaryNotExecutable(let path):
                return path
            }
        }
    }

    /// Validate a candidate app bundle. The default `fileManager` lets tests
    /// inject a stub if they need to; production callers pass nothing.
    static func validate(
        appBundlePath: String,
        helperPlistName: String,
        fileManager: FileManager = .default
    ) -> ValidationFailure? {
        let helperBinaryPath = "\(appBundlePath)/Contents/MacOS/PingWardenHelper"
        let helperPlistPath = "\(appBundlePath)/Contents/Library/LaunchDaemons/\(helperPlistName)"

        if !fileManager.fileExists(atPath: helperBinaryPath) {
            return .binaryMissing(path: helperBinaryPath)
        }
        if !fileManager.fileExists(atPath: helperPlistPath) {
            return .plistMissing(path: helperPlistPath)
        }
        if !fileManager.isExecutableFile(atPath: helperBinaryPath) {
            return .binaryNotExecutable(path: helperBinaryPath)
        }
        return nil
    }
}
