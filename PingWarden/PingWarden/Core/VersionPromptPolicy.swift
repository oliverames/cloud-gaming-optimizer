//
//  VersionPromptPolicy.swift
//  PingWarden
//
//  Decides whether to surface a one-shot prompt (e.g. the donation sheet)
//  on launch. Pure-Foundation so it can be exhaustively tested without
//  spinning up the app.
//
//  Policy: show on truly-first launch, then again only when the user has
//  not seen this *minor* version yet. Patch bumps never re-trigger the
//  prompt — we don't want to ask after a bug-fix release.
//

import Foundation

enum VersionPromptPolicy {
    /// Decide whether to show a one-shot prompt this launch.
    /// - Parameters:
    ///   - currentVersion: the running app's `CFBundleShortVersionString`.
    ///   - lastSeenVersion: the version recorded the last time the prompt
    ///     was shown (or dismissed with "Maybe later"). `nil` on first launch.
    ///   - dismissedPermanently: kill switch set when the user picks
    ///     "Don't ask again".
    static func shouldPrompt(
        currentVersion: String,
        lastSeenVersion: String?,
        dismissedPermanently: Bool
    ) -> Bool {
        if dismissedPermanently {
            return false
        }
        guard let lastSeenVersion else {
            // First launch ever — show.
            return true
        }
        guard let current = parseMajorMinor(currentVersion) else {
            // If we can't parse our own version, fail closed: do not annoy
            // the user with a prompt we can't decide about.
            return false
        }
        guard let lastSeen = parseMajorMinor(lastSeenVersion) else {
            // Malformed persisted value (older build, corrupted defaults).
            // Treat it as effectively unset and show once.
            return true
        }
        if current.major != lastSeen.major {
            return current.major > lastSeen.major
        }
        return current.minor > lastSeen.minor
    }

    /// Extract `(major, minor)` from a semver-shaped string. Anything else
    /// returns `nil` rather than guessing.
    private static func parseMajorMinor(_ version: String) -> (major: Int, minor: Int)? {
        let parts = version.split(separator: ".")
        guard parts.count >= 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]) else {
            return nil
        }
        return (major, minor)
    }
}
