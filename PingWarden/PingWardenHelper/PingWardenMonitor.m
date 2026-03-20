//
//  PingWardenMonitor.m
//  PingWardenHelper
//
//  Core AWDL monitoring using AF_ROUTE socket.
//  Based on james-howard/AWDLControl and jamestut/awdlkiller.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

#import "PingWardenMonitor.h"

#import <os/log.h>
#import <sys/types.h>
#import <sys/ioctl.h>
#import <sys/socket.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <net/route.h>
#import <unistd.h>
#import <poll.h>
#import <errno.h>
#import <err.h>
#import <fcntl.h>
#import <string.h>
#import <stdatomic.h>

#define LOG OS_LOG_DEFAULT

static const char *TARGETIFNAM = "awdl0";

// Static assertion to ensure TARGETIFNAM fits in IFNAMSIZ
// IFNAMSIZ is typically 16 on macOS/BSD
_Static_assert(sizeof("awdl0") <= IFNAMSIZ, "TARGETIFNAM must fit in IFNAMSIZ");

// Routing messages can contain rt_msghdr + if_msghdr + multiple sockaddr structures
// Use a generous buffer size to handle all message types safely
#define RTMSG_BUFFER_SIZE 512

// Invalid file descriptor sentinel
#define INVALID_FD (-1)

@interface PingWardenMonitor () {
    // Pipe file descriptors for internal state change communication
    int _msgfds[2];

    // Thread-safe flag for tracking background thread state
    // Use atomic_bool to prevent data races between main thread and pollIoctl thread
    atomic_bool _threadRunning;

    // Desired AWDL state — accessed from XPC handler threads and the setter,
    // so use atomic_bool to prevent data races.
    atomic_bool _awdlEnabledAtomic;

    dispatch_semaphore_t _ioctlThreadExitSemaphore;
    
    // Counter for AWDL interventions (how many times we brought it down)
    atomic_int _interventionCount;
}

/// Background thread watching AWDL state
@property NSThread *ioctlThread;

/// Socket to perform ioctl to set interface flags
@property int iocfd;

/// Socket to monitor network interface changes (AF_ROUTE)
@property int rtfd;

@end

@implementation PingWardenMonitor

- (instancetype)init {
    if (self = [super init]) {
        // Initialize file descriptors to invalid state for proper cleanup
        _rtfd = INVALID_FD;
        _iocfd = INVALID_FD;
        _msgfds[0] = INVALID_FD;
        _msgfds[1] = INVALID_FD;
        atomic_store(&_threadRunning, false);
        
        // Initialize intervention counter
        atomic_store(&_interventionCount, 0);

        // Start off allowing AWDL to be active
        atomic_store(&_awdlEnabledAtomic, true);

        // Socket to monitor network interface changes
        _rtfd = socket(AF_ROUTE, SOCK_RAW, 0);
        if (_rtfd < 0) {
            os_log_error(LOG, "Error creating AF_ROUTE socket: %d (%s)", errno, strerror(errno));
            [self cleanupFileDescriptors];
            return nil;
        }
        if (fcntl(_rtfd, F_SETFL, O_NONBLOCK) < 0) {
            os_log_error(LOG, "Error setting nonblock on AF_ROUTE socket: %d (%s)", errno, strerror(errno));
            [self cleanupFileDescriptors];
            return nil;
        }

        // Socket to perform ioctl to set interface flags
        _iocfd = socket(AF_INET, SOCK_DGRAM, 0);
        if (_iocfd < 0) {
            os_log_error(LOG, "Error creating AF_INET socket: %d (%s)", errno, strerror(errno));
            [self cleanupFileDescriptors];
            return nil;
        }

        // Pipe for communication from main thread to ioctl thread
        if (0 != pipe(_msgfds)) {
            os_log_error(LOG, "Error creating pipe: %d (%s)", errno, strerror(errno));
            [self cleanupFileDescriptors];
            return nil;
        }
        // Set pipe to non-blocking
        if (fcntl(_msgfds[0], F_SETFL, O_NONBLOCK) < 0) {
            os_log_error(LOG, "Error setting nonblock on pipe read fd: %d (%s)", errno, strerror(errno));
            [self cleanupFileDescriptors];
            return nil;
        }

        // Start background thread
        _ioctlThreadExitSemaphore = dispatch_semaphore_create(0);
        _ioctlThread = [[NSThread alloc] initWithTarget:self selector:@selector(pollIoctl) object:nil];
        _ioctlThread.name = @"PingWardenMonitor.pollIoctl";
        atomic_store(&_threadRunning, true);
        [_ioctlThread start];

        os_log(LOG, "PingWardenMonitor initialized successfully");
    }
    return self;
}

/// Clean up file descriptors on error or dealloc
- (void)cleanupFileDescriptors {
    if (_iocfd != INVALID_FD) {
        close(_iocfd);
        _iocfd = INVALID_FD;
    }
    if (_rtfd != INVALID_FD) {
        close(_rtfd);
        _rtfd = INVALID_FD;
    }
    if (_msgfds[0] != INVALID_FD) {
        close(_msgfds[0]);
        _msgfds[0] = INVALID_FD;
    }
    if (_msgfds[1] != INVALID_FD) {
        close(_msgfds[1]);
        _msgfds[1] = INVALID_FD;
    }
}

/// Bring the interface up or down. Must be run only on ioctlThread.
- (void)ifconfig:(BOOL)up {
    NSAssert([NSThread currentThread] == _ioctlThread, @"ifconfig: must run on ioctlThread");

    struct ifreq ifr = {0};
    strlcpy(ifr.ifr_name, TARGETIFNAM, IFNAMSIZ);

    if (ioctl(_iocfd, SIOCGIFFLAGS, &ifr) < 0) {
        os_log_error(LOG, "Error getting current interface flags: %d (%s)", errno, strerror(errno));
        return;
    }

    if ((ifr.ifr_flags & IFF_UP) && !up) {
        // Interface is UP but we want it DOWN
        ifr.ifr_flags &= ~IFF_UP;
        if (ioctl(_iocfd, SIOCSIFFLAGS, &ifr) < 0) {
            os_log_error(LOG, "Error bringing interface down: %d (%s)", errno, strerror(errno));
        } else {
            os_log_debug(LOG, "Brought awdl0 DOWN");
        }
    } else if (!(ifr.ifr_flags & IFF_UP) && up) {
        // Interface is DOWN but we want it UP
        ifr.ifr_flags |= IFF_UP;
        if (ioctl(_iocfd, SIOCSIFFLAGS, &ifr) < 0) {
            os_log_error(LOG, "Error bringing interface up: %d (%s)", errno, strerror(errno));
        } else {
            os_log_debug(LOG, "Brought awdl0 UP");
        }
    }
    // else: interface is already in desired state, do nothing
}

/// Main method for the background ioctlThread.
/// Watches AWDL interface state and brings it up/down as needed.
- (void)pollIoctl {
    os_log(LOG, "pollIoctl thread started");

    BOOL quit = NO;
    BOOL enable = atomic_load(&_awdlEnabledAtomic);

    while (!quit) {
        struct pollfd fds[] = {
            {
                .fd = _rtfd,
                .events = POLLIN,
                .revents = 0
            },
            {
                .fd = _msgfds[0],
                .events = POLLIN,
                .revents = 0
            }
        };

        // Block until we get a routing message or internal message
        if (poll(fds, 2, -1) < 1) {
            if (errno == EINTR) {
                continue;
            }
            os_log_error(LOG, "Poll error: %d (%s)", errno, strerror(errno));
            break;
        }

        // Check for routing table changes (interface state changes)
        if (fds[0].revents) {
            os_log_debug(LOG, "Network route changed");
            int ifflag = 0;
            // Use larger buffer to handle all routing message types
            // Messages can include sockaddr structures appended after headers
            uint8_t rtmsgbuff[RTMSG_BUFFER_SIZE] = {0};

            for (ssize_t len = 0; !quit;) {
                len = read(_rtfd, rtmsgbuff, sizeof(rtmsgbuff));
                if (len < 0) {
                    if (errno == EINTR) {
                        continue;
                    } else if (errno == EAGAIN) {
                        break;
                    }
                    os_log_error(LOG, "Error reading AF_ROUTE socket: %d (%s)", errno, strerror(errno));
                    break;  // Exit loop on unexpected errors
                }
                if (len == 0) {
                    break;  // Socket closed
                }

                // Validate message length before casting
                if (len < (ssize_t)sizeof(struct rt_msghdr)) {
                    os_log_debug(LOG, "Routing message too short: %zd bytes (min %zu)", len, sizeof(struct rt_msghdr));
                    continue;
                }

                struct rt_msghdr *rtmsg = (void *)rtmsgbuff;

                // Additional validation: check rtm_msglen matches actual data
                if (rtmsg->rtm_msglen > len || rtmsg->rtm_msglen < sizeof(struct rt_msghdr)) {
                    os_log_debug(LOG, "Invalid rtm_msglen: %hu (actual read: %zd)", rtmsg->rtm_msglen, len);
                    continue;
                }

                if (rtmsg->rtm_type != RTM_IFINFO) {
                    continue;
                }

                // Validate we have enough data for if_msghdr
                if (len < (ssize_t)sizeof(struct if_msghdr)) {
                    os_log_debug(LOG, "IFINFO message too short: %zd bytes (min %zu)", len, sizeof(struct if_msghdr));
                    continue;
                }

                // Get interface ID for awdl0
                static int consecutiveIfFailures = 0;
                unsigned int ifidx = if_nametoindex(TARGETIFNAM);
                if (!ifidx) {
                    consecutiveIfFailures++;
                    os_log_error(LOG, "Error getting interface index for %s (%d consecutive failures)",
                                 TARGETIFNAM, consecutiveIfFailures);
                    if (consecutiveIfFailures > 10) {
                        os_log_error(LOG, "Too many failures getting interface - AWDL may not exist on this system");
                        // Don't quit, just log - interface might become available later
                    }
                    continue;
                }
                consecutiveIfFailures = 0;  // Reset on success

                struct if_msghdr *ifmsg = (void *)rtmsg;
                if ((unsigned int)ifmsg->ifm_index != ifidx) {
                    // Not the interface we're watching
                    continue;
                }

                ifflag = ifmsg->ifm_flags;
            }

            // If AWDL was brought UP by the system but we want it DOWN
            // Use the ifconfig method to ensure proper thread-safety checks
            if ((ifflag & IFF_UP) && !enable) {
                // Increment intervention counter (thread-safe atomic operation)
                int count = atomic_fetch_add(&_interventionCount, 1) + 1;
                os_log(LOG, "AWDL intervention #%d - System tried to bring interface UP, blocking it", count);
                [self ifconfig:NO];
            }
        }

        // Check for internal messages (enable/disable/quit)
        if (fds[1].revents) {
            char msg = 0;
            for (ssize_t len = 0; !quit;) {
                len = read(_msgfds[0], &msg, 1);
                if (len < 0) {
                    if (errno == EINTR) {
                        continue;
                    } else if (errno == EAGAIN) {
                        break;
                    }
                    os_log_error(LOG, "Error reading message pipe: %d (%s)", errno, strerror(errno));
                    break;  // Exit loop on unexpected errors
                }
                if (len == 0) {
                    break;  // Pipe closed
                }

                switch (msg) {
                    case 'Q':
                        os_log(LOG, "Received quit message");
                        quit = YES;
                        break;
                    case 'U':
                        os_log(LOG, "Bringing AWDL interface UP (enabling)");
                        enable = YES;
                        [self ifconfig:YES];
                        break;
                    case 'D':
                        os_log(LOG, "Bringing AWDL interface DOWN (disabling)");
                        enable = NO;
                        [self ifconfig:NO];
                        break;
                    default:
                        os_log_debug(LOG, "Unknown message: %c", msg);
                        break;
                }
            }
        }
    }

    atomic_store(&_threadRunning, false);
    dispatch_semaphore_signal(_ioctlThreadExitSemaphore);
    os_log(LOG, "pollIoctl thread exiting");
}

/// Write a single byte to the message pipe with retry logic
- (BOOL)writeMessageToPipe:(const char *)msg {
    if (_msgfds[1] == INVALID_FD) {
        os_log_error(LOG, "Cannot write to pipe: fd is invalid");
        return NO;
    }

    // Retry up to 3 times on EINTR
    for (int retry = 0; retry < 3; retry++) {
        ssize_t written = write(_msgfds[1], msg, 1);
        if (written == 1) {
            return YES;
        }
        if (written < 0) {
            if (errno == EINTR) {
                os_log_debug(LOG, "Write interrupted, retrying (attempt %d)", retry + 1);
                continue;
            }
            os_log_error(LOG, "Error writing to message pipe: %d (%s)", errno, strerror(errno));
            return NO;
        }
        // written == 0 means nothing was written
        os_log_info(LOG, "Partial write to message pipe: wrote %zd bytes", written);
    }
    os_log_error(LOG, "Failed to write message after 3 retries");
    return NO;
}

- (BOOL)awdlEnabled {
    return atomic_load(&_awdlEnabledAtomic);
}

- (BOOL)setAwdlEnabled:(BOOL)enabled {
    const char *msg = enabled ? "U" : "D";
    if (![self writeMessageToPipe:msg]) {
        os_log_error(LOG, "Failed to send %s message to pipe", enabled ? "enable" : "disable");
        return NO;
    }
    atomic_store(&_awdlEnabledAtomic, enabled);
    return YES;
}

- (void)invalidate {
    os_log(LOG, "PingWardenMonitor invalidating...");

    // Only send quit if thread is running (atomic read)
    if (atomic_load(&_threadRunning) && _msgfds[1] != INVALID_FD) {
        // Send quit message to background thread with retry
        if (![self writeMessageToPipe:"Q"]) {
            os_log_error(LOG, "Failed to send quit message to pipe - thread may not exit cleanly");
        }

        // Wait for background thread to exit (with timeout)
        // Use a shorter initial timeout, then check if thread is still running
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC));
        long result = dispatch_semaphore_wait(_ioctlThreadExitSemaphore, timeout);
        if (result != 0) {
            os_log_error(LOG, "Timeout waiting for pollIoctl thread to exit");
            // Mark thread as not running to prevent further issues (atomic write)
            atomic_store(&_threadRunning, false);
        }
    }

    // Clean up file descriptors after thread exits
    [self cleanupFileDescriptors];

    os_log(LOG, "PingWardenMonitor invalidated");
}

- (void)dealloc {
    // Ensure thread is stopped and resources cleaned up (atomic read)
    if (atomic_load(&_threadRunning)) {
        [self invalidate];
    } else {
        [self cleanupFileDescriptors];
    }
}

#pragma mark - Intervention Counter

- (NSInteger)getInterventionCount {
    return atomic_load(&_interventionCount);
}

- (void)resetInterventionCount {
    atomic_store(&_interventionCount, 0);
    os_log(LOG, "Intervention counter reset to 0");
}

@end
