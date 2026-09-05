/*
 * pam_immurok.c - PAM module for immurok authentication
 *
 * This module communicates with immurok-daemon via Unix socket
 * to provide fingerprint authentication.
 *
 * Fail-closed policy for the strong-auth key file
 * (/etc/immurok/pam/<uid>.key, see pam_load_key()):
 *   - File absent (ENOENT)            → compat mode. Strong auth was never
 *                                        opted into; a bare "OK" from the
 *                                        App is accepted like before.
 *   - File present and well-formed    → strong mode. "OK" must carry a
 *                                        correct HMAC over this request's
 *                                        nonce or it's treated as DENY.
 *   - File present but unusable       → ALSO strong mode, with key_valid=0,
 *     (wrong owner/mode/size, symlink)  so the MAC check can never pass.
 *                                        Any "OK" is unconditionally denied.
 * The last case used to silently fall back to compat mode (fail-open): an
 * attacker who could corrupt or replace the key file (e.g. race a reinstall,
 * or an admin-privileged bug elsewhere) got to downgrade strong auth back to
 * "any OK on pam.sock is accepted" without leaving strong-mode enabled. A
 * key file that exists but can't be trusted is a signal something is wrong,
 * not a signal to relax — so we fail closed and drop to the password prompt
 * instead.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/select.h>
#include <errno.h>
#include <pwd.h>
#include <signal.h>
#include <syslog.h>
#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>

#define PAM_SM_AUTH
#define PAM_SM_ACCOUNT
#define PAM_SM_SESSION
#define PAM_SM_PASSWORD

#include <security/pam_modules.h>
#include <security/pam_appl.h>
#include "pam_auth_verify.h"
#include "hmac_sha256.h"

#define TIMEOUT_SEC 40
#define BUFFER_SIZE 256

static const char *spinner_frames[] = {
    "\xe2\xa0\x96", "\xe2\xa0\xb2", "\xe2\xa2\xb2", "\xe2\xa2\xb0",
    "\xe2\xa3\xb0", "\xe2\xa3\xa0", "\xe2\xa3\x84", "\xe2\xa3\x86",
    "\xe2\xa1\x86", "\xe2\xa1\x96"
};
#define SPINNER_FRAME_COUNT 10

/* Send authentication request to immurok.app with animated spinner */
static int authenticate_via_socket(const char *user, const char *service) {
    int sock, tty_fd = -1;
    struct sockaddr_un addr;
    char request[BUFFER_SIZE];
    char response[BUFFER_SIZE];
    char socket_path[256];
    char buf[128];
    ssize_t n;
    int frame = 0;
    uint8_t key[32];
    uint8_t nonce[PAM_NONCE_LEN];
    char nonce_hex[PAM_NONCE_LEN * 2 + 1];
    int strong = 0;
    int key_valid = 0;

    /* Build socket path from target user's home directory */
    struct passwd *pw = getpwnam(user);
    if (pw == NULL || pw->pw_dir == NULL)
        return PAM_AUTH_ERR;

    /* 强认证模式：root 目录里有本用户的 pam_key 时，App 的 OK 必须带对本次
     * nonce 的 HMAC。文件不存在则维持旧行为（兼容模式）。 */
    {
        int rc = pam_load_key(PAM_KEY_DIR_DEFAULT, pw->pw_uid, key);
        if (rc == 1) {
            strong = 1;
            key_valid = 1;
        } else if (rc < 0) {
            /* 密钥文件存在但读不出来（属主/权限/大小不对，或是个符号链接）：
             * 这不是"从没配置过强认证"，是配置被破坏或被篡改的信号，必须
             * fail closed——照样进入强认证模式，但 key_valid=0 让下面 OK
             * 分支的 MAC 检查永远通不过，退回密码，而不是悄悄退回兼容模式
             * 接受一个没有 MAC 保护的裸 OK。 */
            strong = 1;
            key_valid = 0;
            memset(key, 0, sizeof key);
            syslog(LOG_AUTH | LOG_WARNING,
                   "pam_immurok: %s/%u.key exists but is unusable (owner/mode/size) — "
                   "falling back to password (fail closed)",
                   PAM_KEY_DIR_DEFAULT, (unsigned)pw->pw_uid);
            pam_audit_log(user, service, "KEY_FILE_UNUSABLE");
        }
    }
    pam_gen_nonce(nonce);
    pam_hex(nonce, PAM_NONCE_LEN, nonce_hex);

    snprintf(socket_path, sizeof(socket_path), "%s/.immurok/pam.sock", pw->pw_dir);

    sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0)
        return PAM_AUTH_ERR;

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sock);
        return PAM_AUTH_ERR;
    }

    snprintf(request, sizeof(request), "AUTH:%s:%s:%s", user, service, nonce_hex);
    if (send(sock, request, strlen(request), 0) < 0) {
        close(sock);
        return PAM_AUTH_ERR;
    }

    /* Open controlling terminal for spinner output. WRONLY is enough — we
     * never read from /dev/tty here. */
    tty_fd = open("/dev/tty", O_WRONLY);

    /* Catch Ctrl+C via kqueue/EVFILT_SIGNAL rather than a sigaction() handler.
     * A handler would be a function pointer INTO this module, and libpam
     * dlclose()s the module in pam_end() — a lingering reference into unmapped
     * memory crashes the host. A kqueue installs no such pointer: SIGINT is
     * delivered to a file descriptor we poll and close before returning.
     *
     * Why a kqueue at all instead of just trusting EINTR: the host owns the
     * SIGINT disposition and we must work for every case. sudo(8) installs its
     * own handler (init_signals(), no SA_RESTART) so we DO get EINTR there,
     * but other hosts may block or SIG_IGN the signal, in which case select()
     * never returns EINTR. EVFILT_SIGNAL records the signal in all three cases
     * (verified on macOS 26: blocked / handler / SIG_IGN all fire), and the
     * kqueue fd is selectable, so it folds straight into the loop below. */
    int kq = kqueue();
    if (kq >= 0) {
        struct kevent kev;
        EV_SET(&kev, SIGINT, EVFILT_SIGNAL, EV_ADD | EV_CLEAR, 0, 0, NULL);
        if (kevent(kq, &kev, 1, NULL, 0, NULL) < 0) {
            close(kq);
            kq = -1;
        }
    }
    int nfds = sock + 1;
    if (kq >= sock) nfds = kq + 1;

    /* Wait for response with animated spinner */
    fd_set readfds;
    struct timeval tv;
    int total_ms = 0;
    int max_ms = TIMEOUT_SEC * 1000;
    int result = PAM_AUTH_ERR;

    while (total_ms < max_ms) {
        FD_ZERO(&readfds);
        FD_SET(sock, &readfds);
        if (kq >= 0)
            FD_SET(kq, &readfds);
        tv.tv_sec = 0;
        tv.tv_usec = 80000; /* 80ms per frame */

        int ret = select(nfds, &readfds, NULL, NULL, &tv);
        if (ret > 0 && kq >= 0 && FD_ISSET(kq, &readfds)) {
            /* Ctrl+C — abandon the fingerprint wait and let the rest of the
             * auth stack (pam_opendirectory) prompt for a password. Same
             * semantics as the Linux module. Erasing the line also wipes the
             * "^C" the tty echoed onto it, so the password prompt starts
             * clean. Closing the socket below makes the App drop the device's
             * fingerprint gate (LED stops) instead of blinking until timeout. */
            struct kevent out;
            struct timespec ts = { 0, 0 };
            (void)kevent(kq, NULL, 0, &out, 1, &ts);
            if (tty_fd >= 0)
                write(tty_fd, "\r\033[K", 4);
            syslog(LOG_AUTH | LOG_INFO,
                   "pam_immurok: fingerprint wait cancelled by SIGINT (user=%s service=%s)",
                   user, service);
            result = PAM_IGNORE;
            break;
        }
        if (ret > 0 && !FD_ISSET(sock, &readfds)) {
            /* Nothing on the socket (only the kqueue could have been ready,
             * and that's handled above) — keep waiting. */
            ret = 0;
        }
        if (ret > 0) {
            /* Socket readable — read response */
            memset(response, 0, sizeof(response));
            n = recv(sock, response, sizeof(response) - 1, 0);
            if (n > 0 && strncmp(response, "OK", 2) == 0) {
                if (strong && (!key_valid || !pam_verify_response(key, nonce, user, service, response))) {
                    /* 强认证模式下 OK 必须带正确 MAC。key_valid=0（密钥文件不可用，
                     * 已在上面 fail closed）或 MAC 本身算出来不对，都是伪造/配置
                     * 损坏的信号：一律按 DENY 处理，退回密码，并留下审计记录。 */
                    const char *reason = key_valid ? "MAC_MISMATCH" : "KEY_FILE_UNUSABLE";
                    syslog(LOG_AUTH | LOG_WARNING,
                           "pam_immurok: %s (user=%s service=%s) — possible pam.sock spoofing",
                           reason, user, service);
                    pam_audit_log(user, service, reason);
                    if (tty_fd >= 0) {
                        snprintf(buf, sizeof(buf),
                                 "\r\033[K\033[31m\xe2\x9c\x97 Denied\033[0m");
                        write(tty_fd, buf, strlen(buf));
                        usleep(500000);
                        write(tty_fd, "\r\033[K", 4);
                    }
                    result = PAM_AUTH_ERR;
                    break;
                }
                if (tty_fd >= 0) {
                    snprintf(buf, sizeof(buf),
                             "\r\033[K\033[32m\xe2\x9c\x93 Approved!\033[0m");
                    write(tty_fd, buf, strlen(buf));
                    usleep(500000);
                    write(tty_fd, "\r\033[K", 4); /* erase result */
                }
                result = PAM_SUCCESS;
                break;
            } else if (n > 0 && strncmp(response, "RETRY:", 6) == 0) {
                /* Intermediate failure — show remaining attempts, continue spinner */
                int remaining = atoi(response + 6);
                if (tty_fd >= 0) {
                    snprintf(buf, sizeof(buf),
                             "\r\033[K\033[31m\xe2\x9c\x97 Not matched, %d attempt%s left\033[0m",
                             remaining, remaining == 1 ? "" : "s");
                    write(tty_fd, buf, strlen(buf));
                    usleep(500000);
                    write(tty_fd, "\r\033[K", 4); /* erase, resume spinner */
                }
                /* don't break — keep waiting */
            } else if (n > 0 && strncmp(response, "REJECT", 6) == 0) {
                /* User clicked "Reject" in the overlay UI: kill the calling
                 * process (sudo) so the entire command dies — no password
                 * fallback. macOS PAM's `sufficient` chain would otherwise
                 * fall through to pam_opendirectory and prompt for a
                 * password, which contradicts the user's "no, do not run
                 * this" intent. SIGTERM lets sudo exit cleanly (cleanup
                 * handlers run, terminal isn't left in raw mode). */
                if (tty_fd >= 0) {
                    snprintf(buf, sizeof(buf),
                             "\r\033[K\033[31m\xe2\x9c\x97 Rejected by user\033[0m\r\n");
                    write(tty_fd, buf, strlen(buf));
                }
                /* pam_immurok runs INSIDE sudo's process (it's a dlopen'd
                 * .so), so getpid()=sudo and getppid()=sudo's launcher
                 * (imk via env). We want to kill sudo itself, not its
                 * parent — `raise(SIGTERM)` targets the current process. */
                syslog(LOG_AUTH | LOG_NOTICE,
                       "pam_immurok: user rejected auth, raising SIGTERM in sudo (pid=%d)",
                       getpid());
                raise(SIGTERM);
                /* Don't return — give the signal a moment to be delivered
                 * before any further PAM logic runs. _exit() bypasses
                 * sudo's signal handlers entirely, ensuring the password
                 * prompt never happens. EX_NOPERM (77) is the conventional
                 * "auth refused" exit code. */
                _exit(77);
            } else if (n > 0 && strncmp(response, "SKIP", 4) == 0) {
                /* Feature disabled in app settings — stay completely
                 * silent (no "✗ Denied" flash) and let the stack fall
                 * through to the password prompt. */
                result = PAM_IGNORE;
                break;
            } else {
                /* Final failure (DENY/TIMEOUT/other) — fall through to
                 * remaining auth modules (password prompt). */
                if (tty_fd >= 0) {
                    snprintf(buf, sizeof(buf),
                             "\r\033[K\033[31m\xe2\x9c\x97 Denied\033[0m");
                    write(tty_fd, buf, strlen(buf));
                    usleep(500000);
                    write(tty_fd, "\r\033[K", 4); /* erase result */
                }
                break;
            }
        } else if (ret == 0) {
            /* Timeout — update spinner */
            if (tty_fd >= 0) {
                snprintf(buf, sizeof(buf),
                         "\r\033[K\033[33m%s Please verify your fingerprint...\033[0m",
                         spinner_frames[frame % SPINNER_FRAME_COUNT]);
                write(tty_fd, buf, strlen(buf));
            }
            frame++;
            total_ms += 80;
        } else {
            /* EINTR: a signal ran a host handler (sudo records SIGINT in its
             * own pipe and returns). Don't decide anything here — loop once
             * more and let the kqueue branch above tell us whether it was
             * SIGINT. Any other signal (SIGWINCH on a window resize, ...)
             * must NOT abort a fingerprint wait. */
            if (errno == EINTR) continue;
            break; /* real select error */
        }
    }

    if (total_ms >= max_ms && result != PAM_SUCCESS) {
        if (tty_fd >= 0) {
            snprintf(buf, sizeof(buf),
                     "\r\033[K\033[31m\xe2\x9c\x97 Time out\033[0m");
            write(tty_fd, buf, strlen(buf));
            usleep(500000);
            write(tty_fd, "\r\033[K", 4); /* erase result */
        }
    }

    /* Tear the kqueue down before returning: no handler was installed, so
     * nothing points into this module once we're back in libpam and it is
     * free to dlclose() us in pam_end(). */
    if (kq >= 0)
        close(kq);
    if (tty_fd >= 0)
        close(tty_fd);
    close(sock);
    secure_zero(key, sizeof key);
    return result;
}

/* PAM authentication function */
PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags,
                                    int argc, const char **argv) {
    const char *user = NULL;
    const char *service = NULL;

    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL)
        return PAM_AUTH_ERR;

    if (pam_get_item(pamh, PAM_SERVICE, (const void **)&service) != PAM_SUCCESS || service == NULL)
        service = "unknown";

    return authenticate_via_socket(user, service);
}

/* Required PAM stubs */
PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) { return PAM_SUCCESS; }
PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv) { return PAM_SUCCESS; }
PAM_EXTERN int pam_sm_open_session(pam_handle_t *pamh, int flags, int argc, const char **argv) { return PAM_SUCCESS; }
PAM_EXTERN int pam_sm_close_session(pam_handle_t *pamh, int flags, int argc, const char **argv) { return PAM_SUCCESS; }
PAM_EXTERN int pam_sm_chauthtok(pam_handle_t *pamh, int flags, int argc, const char **argv) { return PAM_SUCCESS; }
