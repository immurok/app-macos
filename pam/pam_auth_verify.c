#include "pam_auth_verify.h"
#include "hmac_sha256.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <errno.h>
#include <time.h>

static const char MAC_PREFIX[] = "immurok-pam-v1";   /* 不含 NUL，14 字节 */

int pam_load_key(const char *dir, uid_t uid, uint8_t key[32]) {
    char path[512];
    snprintf(path, sizeof path, "%s/%u.key", dir, (unsigned)uid);

    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0)
        return -1 * (errno != ENOENT && errno != ENOTDIR);   /* ENOENT → 0，其它（含 ELOOP 符号链接）→ -1 */

    struct stat st;
    int rc = -1;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)
        && (st.st_mode & 077) == 0
        && st.st_size == 32
        /* 生产环境文件属主必须是 root；非 root 单测环境下允许属主是自己 */
        && (st.st_uid == 0 || st.st_uid == geteuid())) {
        ssize_t n = read(fd, key, 32);
        if (n == 32) rc = 1;
    }
    close(fd);
    if (rc != 1) secure_zero(key, 32);
    return rc;
}

void pam_gen_nonce(uint8_t nonce[PAM_NONCE_LEN]) {
    arc4random_buf(nonce, PAM_NONCE_LEN);
}

void pam_hex(const uint8_t *in, size_t n, char *out) {
    static const char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        out[2 * i] = digits[in[i] >> 4];
        out[2 * i + 1] = digits[in[i] & 0x0f];
    }
    out[2 * n] = 0;
}

static int unhex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

int pam_compute_mac(const uint8_t key[32], const uint8_t nonce[PAM_NONCE_LEN],
                    const char *user, const char *service, uint8_t mac[PAM_MAC_LEN]) {
    size_t ul = strlen(user), sl = strlen(service);
    size_t n = sizeof(MAC_PREFIX) - 1 + PAM_NONCE_LEN + ul + 1 + sl + 1;
    uint8_t *msg = malloc(n);
    if (!msg) return -1;
    size_t p = 0;
    memcpy(msg + p, MAC_PREFIX, sizeof(MAC_PREFIX) - 1); p += sizeof(MAC_PREFIX) - 1;
    memcpy(msg + p, nonce, PAM_NONCE_LEN); p += PAM_NONCE_LEN;
    memcpy(msg + p, user, ul); p += ul; msg[p++] = 0;
    memcpy(msg + p, service, sl); p += sl; msg[p++] = 0;
    uint8_t full[32];
    hmac_sha256(key, 32, msg, p, full);
    memcpy(mac, full, PAM_MAC_LEN);
    secure_zero(full, sizeof full);
    free(msg);
    return 0;
}

int pam_verify_response(const uint8_t key[32], const uint8_t nonce[PAM_NONCE_LEN],
                        const char *user, const char *service, const char *response) {
    if (strncmp(response, "OK:", 3) != 0) return 0;
    const char *hex = response + 3;
    uint8_t got[PAM_MAC_LEN];
    for (int i = 0; i < PAM_MAC_LEN; i++) {
        int hi = unhex_nibble(hex[2 * i]);
        if (hi < 0) return 0;                       /* 也覆盖提前遇到 NUL 的情况 */
        int lo = unhex_nibble(hex[2 * i + 1]);
        if (lo < 0) return 0;
        got[i] = (uint8_t)((hi << 4) | lo);
    }
    uint8_t want[PAM_MAC_LEN];
    if (pam_compute_mac(key, nonce, user, service, want) != 0) return 0;
    uint8_t diff = 0;
    for (int i = 0; i < PAM_MAC_LEN; i++) diff |= got[i] ^ want[i];
    return diff == 0;
}

void pam_audit_log_to(const char *path, const char *user, const char *service, const char *reason) {
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) return;   /* 非 root 对已存在的 root 0644 文件无写权限、或其它打开失败：静默放弃，不影响认证结果 */

    time_t now = time(NULL);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%dT%H:%M:%S%z", &tm_buf);

    char line[256];
    int len = snprintf(line, sizeof line, "%s pid=%d user=%s service=%s %s\n",
                        ts, (int)getpid(), user, service, reason);
    if (len > 0) {
        size_t wlen = (len < (int)sizeof line) ? (size_t)len : sizeof line - 1;
        write(fd, line, wlen);
    }
    close(fd);
}
