//
//  PingWardenMonitor.h
//  PingWardenHelper
//
//  Monitors AWDL interface state using AF_ROUTE socket.
//  Based on james-howard/AWDLControl and jamestut/awdlkiller.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Monitors and controls the AWDL (awdl0) network interface.
/// Uses AF_ROUTE socket for kernel-level monitoring with <1ms response time.
/// When awdlEnabled is NO, any attempt by the system to bring awdl0 UP
/// is immediately countered by bringing it back DOWN.
@interface PingWardenMonitor : NSObject

/// When YES, AWDL is allowed to be up (normal operation).
/// When NO, AWDL is kept down (blocking mode).
/// Reading returns the current desired state.
@property (nonatomic, readonly) BOOL awdlEnabled;

/// Set the AWDL enabled state. Returns YES if the command was successfully
/// queued to the background thread, NO if the pipe write failed.
- (BOOL)setAwdlEnabled:(BOOL)enabled;

/// Stop the monitoring thread and cleanup all resources.
/// Should be called before the helper exits.
- (void)invalidate;

/// Bring awdl0 back UP with a direct ioctl on the calling thread.
/// Exit-path safety net: works even if the poll thread is dead or the
/// control pipe is gone. Call only after `invalidate`.
- (void)restoreInterfaceUpDirectly;

/// Get the total number of AWDL interventions (how many times we blocked AWDL from coming up)
/// This counter persists for the lifetime of the helper process
- (NSInteger)getInterventionCount;

/// Reset the intervention counter to zero
- (void)resetInterventionCount;

@end

NS_ASSUME_NONNULL_END
