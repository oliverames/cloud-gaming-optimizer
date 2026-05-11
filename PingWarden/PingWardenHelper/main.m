//
//  main.m
//  PingWardenHelper
//
//  XPC service entry point for the privileged helper daemon.
//  Registered via SMAppService, runs as LaunchDaemon.
//  Based on james-howard/AWDLControl architecture.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <os/log.h>

#import "../Common/HelperProtocol.h"
#import "PingWardenMonitor.h"

#define LOG OS_LOG_DEFAULT
#define HELPER_VERSION @"2.2.2"

// Team ID for code signing validation
#define TEAM_ID @"PV3W52NDZ3"

// Grace period before exiting when all connections close. Long enough that an
// app crash + SMAppService relaunch can re-establish XPC without the helper
// tearing down monitoring and re-enabling AWDL mid-session.
#define EXIT_GRACE_PERIOD_SECONDS 60.0

static NSInteger activeConnectionCount = 0;
static dispatch_queue_t connectionCountQueue;
static dispatch_source_t exitTimer = nil;

#pragma mark - Code Signing Helpers

/// Check if this binary is properly code signed (not ad-hoc)
static BOOL isProperlyCodeSigned(void) {
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCopySelf(kSecCSDefaultFlags, &code);
    if (status != errSecSuccess || !code) {
        return NO;
    }

    // Check for valid signature (not ad-hoc)
    SecRequirementRef requirement = NULL;
    NSString *reqString = [NSString stringWithFormat:
        @"anchor apple generic and certificate leaf[subject.OU] = \"%@\"", TEAM_ID];
    status = SecRequirementCreateWithString((__bridge CFStringRef)reqString,
                                            kSecCSDefaultFlags, &requirement);
    if (status != errSecSuccess || !requirement) {
        CFRelease(code);
        return NO;
    }

    status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    CFRelease(code);
    CFRelease(requirement);

    return status == errSecSuccess;
}

#pragma mark - AWDLService

@interface PingWardenService : NSObject <PingWardenHelperProtocol, NSXPCListenerDelegate>

@property (strong) PingWardenMonitor *monitor;

@end

@implementation PingWardenService

- (instancetype)init {
    if (self = [super init]) {
        self.monitor = [PingWardenMonitor new];
        if (!self.monitor) {
            os_log_error(LOG, "Failed to initialize PingWardenMonitor");
            return nil;
        }
    }
    return self;
}

#pragma mark - PingWardenHelperProtocol

- (void)isAWDLEnabledWithReply:(void (^)(BOOL))reply {
    BOOL enabled = self.monitor.awdlEnabled;
    os_log_debug(LOG, "isAWDLEnabled: %d", enabled);
    reply(enabled);
}

- (void)setAWDLEnabled:(BOOL)enable withReply:(void (^)(BOOL))reply {
    os_log(LOG, "setAWDLEnabled: %d", enable);

    // Apply the state change - this sends a message to the monitoring thread
    // which will then bring the interface UP or DOWN as needed.
    // setAwdlEnabled: returns YES if the pipe write succeeded (command queued),
    // NO if the pipe write failed. The ivar is only updated on success.
    BOOL success = [self.monitor setAwdlEnabled:enable];
    if (!success) {
        os_log_error(LOG, "setAWDLEnabled failed: pipe write error for requested state %d", enable);
    }

    reply(success);
}

- (void)getAWDLStatusWithReply:(void (^)(NSString *))reply {
    NSString *status = self.monitor.awdlEnabled ? @"AWDL Enabled (allowing UP)" : @"AWDL Disabled (keeping DOWN)";
    os_log_debug(LOG, "getAWDLStatus: %{public}@", status);
    reply(status);
}

- (void)getVersionWithReply:(void (^)(NSString *))reply {
    os_log_debug(LOG, "getVersion: %{public}@", HELPER_VERSION);
    reply(HELPER_VERSION);
}

- (void)getAWDLInterventionCountWithReply:(void (^)(NSInteger))reply {
    NSInteger count = [self.monitor getInterventionCount];
    os_log_debug(LOG, "getAWDLInterventionCount: %ld", (long)count);
    reply(count);
}

- (void)resetAWDLInterventionCountWithReply:(void (^)(BOOL))reply {
    [self.monitor resetInterventionCount];
    os_log_debug(LOG, "resetAWDLInterventionCount called");
    reply(YES);
}

#pragma mark - Lifecycle

- (void)cancelExitTimer {
    if (exitTimer) {
        dispatch_source_cancel(exitTimer);
        exitTimer = nil;
        os_log_debug(LOG, "Exit timer cancelled - new connection established");
    }
}

- (void)scheduleExit {
    os_log(LOG, "All XPC connections closed, scheduling exit in %.1f seconds", EXIT_GRACE_PERIOD_SECONDS);

    // Cancel any existing timer
    [self cancelExitTimer];

    // Create a new timer that allows reconnection within grace period
    exitTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(exitTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            os_log(LOG, "Exit timer fired but service deallocated");
            exit(0);
        }

        // Double-check no connections were established during grace period
        // Use dispatch_async to avoid potential deadlock with main queue
        dispatch_async(connectionCountQueue, ^{
            NSInteger currentCount = activeConnectionCount;

            // Return to main queue for the actual exit logic
            dispatch_async(dispatch_get_main_queue(), ^{
                if (currentCount > 0) {
                    os_log(LOG, "Exit cancelled - %ld active connection(s)", (long)currentCount);
                    return;
                }

                os_log(LOG, "Grace period expired, restoring AWDL and exiting");

                // Restore AWDL to enabled state before exiting
                [strongSelf.monitor setAwdlEnabled:YES];
                [strongSelf.monitor invalidate];

                // Give a moment for cleanup, then exit
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    os_log(LOG, "PingWardenHelper exiting");
                    exit(0);
                });
            });
        });
    });

    dispatch_source_set_timer(exitTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(EXIT_GRACE_PERIOD_SECONDS * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(exitTimer);
}

#pragma mark - NSXPCListenerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)conn {
    os_log(LOG, "New XPC connection from PID %d (euid: %d)", conn.processIdentifier, conn.effectiveUserIdentifier);

    // Defense-in-depth: even when connectionCodeSigningRequirement is set,
    // reject connections from unexpected user IDs. On unsigned/dev builds this
    // is the *only* protection since the code-signing requirement is absent.
    uid_t callerEUID = conn.effectiveUserIdentifier;
    uid_t myEUID = geteuid();
    // Allow: root (0), same user as helper, and console users (UID >= 501).
    // Reject system/daemon UIDs (1–500). The helper runs as root via
    // LaunchDaemon; legitimate callers are the app running as the logged-in user.
    if (callerEUID != 0 && callerEUID != myEUID && callerEUID < 501) {
        os_log_error(LOG, "Rejecting XPC connection from unexpected euid %d (helper euid %d)", callerEUID, myEUID);
        return NO;
    }

    // Cancel pending exit if a new connection arrives
    [self cancelExitTimer];

    // Use dispatch_async to avoid potential deadlock from XPC callback context
    dispatch_async(connectionCountQueue, ^{
        activeConnectionCount++;
        os_log_debug(LOG, "Active connections: %ld", (long)activeConnectionCount);
    });

    __weak typeof(self) weakSelf = self;

    conn.interruptionHandler = ^{
        os_log(LOG, "XPC connection interrupted");
    };

    conn.invalidationHandler = ^{
        os_log(LOG, "XPC connection invalidated");

        // Use dispatch_async to avoid deadlock
        dispatch_async(connectionCountQueue, ^{
            activeConnectionCount--;
            os_log_debug(LOG, "Active connections after invalidation: %ld", (long)activeConnectionCount);

            if (activeConnectionCount <= 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf scheduleExit];
                });
            }
        });
    };

    conn.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PingWardenHelperProtocol)];
    conn.exportedObject = self;
    [conn resume];

    return YES;
}

@end

#pragma mark - Signal Handling

/// Set up dispatch source for SIGTERM handling (async-signal-safe)
/// This is the modern, safe approach for handling signals in dispatch-based apps
static dispatch_source_t setupSignalHandler(PingWardenService *service) {
    // Block SIGTERM so we can handle it via dispatch
    signal(SIGTERM, SIG_IGN);

    dispatch_source_t signalSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL,
        SIGTERM,
        0,
        dispatch_get_main_queue()
    );

    if (signalSource) {
        dispatch_source_set_event_handler(signalSource, ^{
            os_log(LOG, "Received SIGTERM via dispatch, performing graceful shutdown");
            if (service && service.monitor) {
                [service.monitor setAwdlEnabled:YES];
                [service.monitor invalidate];
            }
            os_log(LOG, "PingWardenHelper exiting due to SIGTERM");
            // Give a moment for cleanup
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                exit(0);
            });
        });
        dispatch_resume(signalSource);
    }

    return signalSource;
}

#pragma mark - Main

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        BOOL isSigned = isProperlyCodeSigned();
        os_log(LOG, "PingWardenHelper v%{public}@ starting (%{public}s)",
               HELPER_VERSION, isSigned ? "signed" : "unsigned/ad-hoc");

        // Initialize thread-safe queue for connection counting
        connectionCountQueue = dispatch_queue_create("com.amesvt.pingwarden.helper.connectionCount",
                                                     DISPATCH_QUEUE_SERIAL);

        // Initialize the service
        PingWardenService *service = [PingWardenService new];
        if (!service) {
            os_log_error(LOG, "Failed to create PingWardenService, exiting");
            return EXIT_FAILURE;
        }

        // Create XPC listener for our Mach service
        // The service name must match the MachServices key in the plist
        NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:@"com.amesvt.pingwarden.xpc"];

        if (!listener) {
            os_log_error(LOG, "Failed to create XPC listener - Mach service may not be registered");
            os_log_error(LOG, "Ensure the helper plist is in Contents/Library/LaunchDaemons/");
            return EXIT_FAILURE;
        }

        // For production builds, enforce code signing requirement
        // This prevents unauthorized processes from connecting to the helper
        // Allow connections from both the main app and the widget
        if (isSigned) {
            NSString *requirement = [NSString stringWithFormat:
                @"anchor apple generic "
                @"and (identifier \"com.amesvt.pingwarden\" or identifier \"com.amesvt.pingwarden.widget\") "
                @"and certificate leaf[subject.OU] = \"%@\"", TEAM_ID];
            os_log(LOG, "Enforcing code signing requirement for XPC connections (app and widget)");
            // Note: setConnectionCodeSigningRequirement is available in macOS 13+
            // For older versions, manual validation would be needed in shouldAcceptNewConnection
            if (@available(macOS 13.0, *)) {
                listener.connectionCodeSigningRequirement = requirement;
            }
        } else {
            os_log(LOG, "WARNING: Running without code signing requirement - relying on UID-based validation only");
        }

        listener.delegate = service;
        [listener activate];

        os_log(LOG, "XPC listener activated on com.amesvt.pingwarden.xpc");

        // Set up signal handler for graceful shutdown (async-signal-safe via dispatch)
        // The dispatch source is retained by GCD internally, so we don't need to keep a reference
        dispatch_source_t signalSource = setupSignalHandler(service);
        if (!signalSource) {
            os_log_error(LOG, "Failed to set up signal handler - graceful SIGTERM handling disabled");
        }
        (void)signalSource;  // Suppress unused variable warning - dispatch retains internally

        os_log(LOG, "Entering run loop");

        // Enter the main run loop - we'll exit when all connections are closed
        dispatch_main();

        os_log(LOG, "PingWardenHelper main() exiting");
    }
    return EXIT_SUCCESS;
}
