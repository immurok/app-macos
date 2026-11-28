/*
 * la_race.m - Touch ID / Apple Watch request for pam_immurok's `tid` option.
 * See la_race.h.
 */
#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#include <unistd.h>
#include <syslog.h>
#include "la_race.h"

static LAContext *g_ctx;
static dispatch_semaphore_t g_done;

static int start_as_current_euid(const char *reason, int notify_fd);

int la_race_start(const char *reason, int notify_fd, uid_t user) {
    if (g_ctx != nil)
        return -1;
    uid_t saved = geteuid();
    int switched = 0;
    if (saved == 0 && user != 0) {
        if (seteuid(user) != 0)
            return -1;
        switched = 1;
    }
    int rc = start_as_current_euid(reason, notify_fd);
    if (switched && seteuid(saved) != 0) {
        /* Could not get root back. Don't leave a request running; sudo will
         * fail on its own since it is no longer root (fails closed). */
        syslog(LOG_AUTH | LOG_ERR, "pam_immurok: seteuid(%u) restore failed", (unsigned)saved);
        la_race_finish(1);
        return -1;
    }
    return rc;
}

static int start_as_current_euid(const char *reason, int notify_fd) {
    @autoreleasepool {
        LAContext *ctx = [[LAContext alloc] init];
        /* Hide the dialog's "Enter Password" button: the password fallback is
         * the rest of the PAM stack (Ctrl+C → pam_opendirectory). */
        ctx.localizedFallbackTitle = @"";

        LAPolicy policy = LAPolicyDeviceOwnerAuthenticationWithBiometricsOrCompanion;  /* Touch ID and Apple Watch, in parallel */
        NSError *err = nil;
        if (![ctx canEvaluatePolicy:policy error:&err])
            return -1;

        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        NSString *why = [NSString stringWithUTF8String:(reason ? reason : "authenticate")];
        [ctx evaluatePolicy:policy
            localizedReason:why
                      reply:^(BOOL success, NSError *error) {
            (void)error;
            char c = success ? 'Y' : 'N';
            (void)write(notify_fd, &c, 1);
            dispatch_semaphore_signal(done);
        }];
        g_ctx = ctx;
        g_done = done;
        return 0;
    }
}

void la_race_finish(int cancel) {
    @autoreleasepool {
        if (g_ctx == nil)
            return;
        if (cancel)
            [g_ctx invalidate];
        /* invalidate makes LocalAuthentication call the reply block with an
         * error; wait for it so the block never runs after we return. */
        (void)dispatch_semaphore_wait(g_done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        g_ctx = nil;
        g_done = nil;
    }
}
