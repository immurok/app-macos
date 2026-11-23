/*
 * la_race.h - Touch ID / Apple Watch request that runs alongside the immurok
 * fingerprint wait (enabled with the `tid` module option).
 *
 * The request is started asynchronously; its result is delivered as one byte
 * written to `notify_fd` ('Y' = approved, 'N' = failed / cancelled), so the
 * caller can fold it into its select() loop.
 */
#ifndef LA_RACE_H
#define LA_RACE_H

#include <sys/types.h>

/* Start a LocalAuthentication request (biometrics or Apple Watch) for `user`.
 * LocalAuthentication checks the biometrics of the process's effective user,
 * and inside sudo that is root (no enrolled fingers). So when running as root
 * the effective uid is switched to `user` just while the request is created
 * and started, then switched back to root.
 * Returns 0 if started, -1 if Touch ID / Watch is not available right now
 * (no sensor, lid closed, no paired Watch, ...) or the uid switch failed.
 * Only one request at a time. */
int la_race_start(const char *reason, int notify_fd, uid_t user);

/* Finish the request started by la_race_start(). With cancel=1 the dialog is
 * dismissed first. Waits (bounded) for the reply callback to run, so nothing
 * is left in flight when the module returns to libpam. Safe to call when no
 * request is active. */
void la_race_finish(int cancel);

#endif
