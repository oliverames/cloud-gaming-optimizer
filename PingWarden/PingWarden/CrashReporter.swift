//
//  CrashReporter.swift
//  PingWarden
//
//  Anonymous crash reporting via Sentry. The Sentry SDK is added as an SPM
//  dependency; this file is inert (no-op) until the package is linked,
//  thanks to the `#if canImport(Sentry)` guards.
//
//  Privacy posture (matches the app's stated promise):
//    • Default OFF — users opt in via
//      Settings → Advanced → Privacy. The choice persists; only fresh
//      installs and existing users launching v2.3.1 see the default.
//    • No IP address (sendDefaultPii = false).
//    • No network breadcrumbs, spans, or failed-request events — those
//      would otherwise leak updater and TCP-probe URLs into crash payloads.
//    • No performance tracing or profiling — crashes only.
//    • No app-lifecycle session tracking (enableAutoSessionTracking = false).
//    • beforeSend re-checks the preference as defense-in-depth, so a
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

    /// Initialize Sentry if (a) the SDK is linked and (b) the user has not
    /// opted in. Call once at app launch, before the first opportunity for a
    /// crash. Turning reporting off is enforced immediately by `beforeSend`;
    /// turning it on requires a relaunch so the SDK can initialize cleanly.
    static func startIfEnabled() {
        guard PingWardenPreferences.shared.isCrashReportingEnabled else {
            log.info("Crash reporting opted out by user; Sentry not initialized")
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

            // Session tracking sends app-start / app-end events labeled
            // with the release. That's useful for Sentry's "crash-free
            // sessions" health metric, but it qualifies as usage telemetry
            // and contradicts the README's privacy claim. Off by choice:
            // we capture crashes only, not lifecycle events.
            options.enableAutoSessionTracking = false

            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
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
