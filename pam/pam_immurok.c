/*
 * pam_immurok.c - PAM module for immurok authentication
 *
 * This module communicates with immurok-daemon via Unix socket
 * to provide fingerprint authentication.
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
#include <syslog.h>

#define PAM_SM_AUTH
#define PAM_SM_ACCOUNT
#define PAM_SM_SESSION
#define PAM_SM_PASSWORD

#include <security/pam_modules.h>
#include <security/pam_appl.h>

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

    /* Build socket path from target user's home directory */
    struct passwd *pw = getpwnam(user);
    if (pw == NULL || pw->pw_dir == NULL)
        return PAM_AUTH_ERR;
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

    snprintf(request, sizeof(request), "AUTH:%s:%s", user, service);
    if (send(sock, request, strlen(request), 0) < 0) {
        close(sock);
        return PAM_AUTH_ERR;
    }

    /* Open controlling terminal for spinner output */
    tty_fd = open("/dev/tty", O_WRONLY);

    /* Wait for response with animated spinner */
    fd_set readfds;
    struct timeval tv;
    int total_ms = 0;
    int max_ms = TIMEOUT_SEC * 1000;
    int result = PAM_AUTH_ERR;

    while (total_ms < max_ms) {
        FD_ZERO(&readfds);
        FD_SET(sock, &readfds);
        tv.tv_sec = 0;
        tv.tv_usec = 80000; /* 80ms per frame */

        int ret = select(sock + 1, &readfds, NULL, NULL, &tv);
        if (ret > 0) {
            /* Socket readable — read response */
            memset(response, 0, sizeof(response));
            n = recv(sock, response, sizeof(response) - 1, 0);
            if (n > 0 && strncmp(response, "OK", 2) == 0) {
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
            } else {
                /* Final failure (DENY/TIMEOUT/other) */
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
            break; /* select error */
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

    if (tty_fd >= 0)
        close(tty_fd);
    close(sock);
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
