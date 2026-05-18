//
//  CrashReporter.swift
//  PingWarden
//
//  Opt-in crash reporting via Sentry. The Sentry SDK is added as an SPM
//  dependency; this file is inert (no-op) until the package is linked,
//  thanks to the `#if canImport(Sentry)` guards.
//
//  Privacy posture (matches the app's stated promise):
//    • Default OFF — user must opt in via Settings → Advanced → Privacy.
//    • No IP address (sendDefaultPii = false).
//    • No network breadcrumbs — would otherwise leak TCP-probe target
//      hostnames (e.g. user's DNS server) into crash payloads.
//    • No performance tracing or profiling — crashes only.
//    • beforeSend re-checks the opt-in preference as defense-in-depth, so a
//      racing toggle-off between SDK init and first event still suppresses.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

import Foundation
import os.log

#if canImport(Sentry)
import Sentry
#endif

private let log = Logger(subsystem: "com.amesvt.pingwarden", category: "CrashReporter")

enum CrashReporter {
    /// Sentry DSN. Not a secret — DSNs are designed to be embedded in
    /// distributed client binaries; Sentry enforces project-side scrubbing.
    private static let dsn = "https://3492628142810aa2deb988baaec35d0c@o4511410883985408.ingest.us.sentry.io/4511410888704000"

    /// Initialize Sentry if (a) the SDK is linked and (b) the user has opted in.
    /// Call once at app launch, before the first opportunity for a crash.
    /// Toggle changes at runtime require an app restart to take effect.
    static func startIfEnabled() {
        guard PingWardenPreferences.shared.isCrashReportingEnabled else {
            log.info("Crash reporting disabled by preference; Sentry not initialized")
            return
        }

        #if canImport(Sentry)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

        SentrySDK.start { options in
            options.dsn = Self.dsn
            options.releaseName = "com.amesvt.pingwarden@\(version)+\(build)"
            options.environment = "production"

            options.debug = false

            options.sendDefaultPii = false

            options.tracesSampleRate = 0.0
            // Profiling is off by default in sentry-cocoa 9.x; no Options
            // property to set explicitly. Tracing must stay 0.0 above —
            // profiling is sampled as a subset of traces, so 0% tracing
            // → 0% profiling regardless.

            options.enableCrashHandler = true
            options.enableAutoSessionTracking = true

            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableAppHangTracking = false
            options.enableFileIOTracing = false

            options.beforeSend = { event in
                guard PingWardenPreferences.shared.isCrashReportingEnabled else {
                    return nil
                }
                return event
            }
        }
        log.info("Sentry initialized for crash reporting (release: \(version, privacy: .public))")
        #else
        log.notice("Sentry SDK not linked; add via SPM: https://github.com/getsentry/sentry-cocoa")
        #endif
    }
}
