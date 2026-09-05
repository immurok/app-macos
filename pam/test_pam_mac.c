/* PAM 信道 MAC 单元测试。make test 运行。 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include "hmac_sha256.h"
#include "test_vectors.h"
#include "pam_auth_verify.h"
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); failures++; } } while (0)

static size_t unhex(const char *hex, uint8_t *out, size_t max) {
    size_t n = strlen(hex) / 2;
    if (n > max) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned v;
        if (sscanf(hex + 2 * i, "%2x", &v) != 1) return 0;
        out[i] = (uint8_t)v;
    }
    return n;
}

static void test_sha256_known(void) {
    /* SHA256("abc") = ba7816bf... */
    uint8_t out[32], want[32];
    sha256((const uint8_t *)"abc", 3, out);
    unhex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", want, 32);
    CHECK(memcmp(out, want, 32) == 0, "sha256(abc)");
}

static void test_hmac_rfc4231_case2(void) {
    /* RFC 4231 test case 2: key="Jefe", data="what do ya want for nothing?" */
    uint8_t out[32], want[32];
    hmac_sha256((const uint8_t *)"Jefe", 4,
                (const uint8_t *)"what do ya want for nothing?", 28, out);
    unhex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", want, 32);
    CHECK(memcmp(out, want, 32) == 0, "hmac rfc4231 case 2");
}

static void test_vectors_mac(void) {
    for (int i = 0; i < PAM_VEC_COUNT; i++) {
        const struct pam_vec *v = &PAM_VECS[i];
        uint8_t key[32], nonce[16], want[16], full[32];
        CHECK(unhex(v->key_hex, key, 32) == 32, "vec key len");
        CHECK(unhex(v->nonce_hex, nonce, 16) == 16, "vec nonce len");
        CHECK(unhex(v->mac_hex, want, 16) == 16, "vec mac len");
        uint8_t msg[256];
        size_t n = 0;
        memcpy(msg + n, "immurok-pam-v1", 14); n += 14;
        memcpy(msg + n, nonce, 16); n += 16;
        memcpy(msg + n, v->user, strlen(v->user)); n += strlen(v->user); msg[n++] = 0;
        memcpy(msg + n, v->service, strlen(v->service)); n += strlen(v->service); msg[n++] = 0;
        hmac_sha256(key, 32, msg, n, full);
        CHECK(memcmp(full, want, 16) == 0, "vec mac matches");
    }
}

static void test_secure_zero(void) {
    /* 行为检查：secure_zero 清除缓冲区内容（无法证明编译器不消除，仅测清零逻辑） */
    uint8_t buf[32];
    memset(buf, 0xAA, sizeof buf);
    secure_zero(buf, sizeof buf);
    uint8_t zero[32] = {0};
    CHECK(memcmp(buf, zero, sizeof buf) == 0, "secure_zero clears buffer");
}

static void write_file(const char *path, const uint8_t *data, size_t n, mode_t mode) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (fd < 0) { perror(path); exit(2); }
    write(fd, data, n);
    fchmod(fd, mode);
    close(fd);
}

static void test_verify_response_vectors(void) {
    for (int i = 0; i < PAM_VEC_COUNT; i++) {
        const struct pam_vec *v = &PAM_VECS[i];
        uint8_t key[32], nonce[16];
        unhex(v->key_hex, key, 32);
        unhex(v->nonce_hex, nonce, 16);
        char good[64], bad[64];
        snprintf(good, sizeof good, "OK:%s", v->mac_hex);
        snprintf(bad, sizeof bad, "OK:%s", v->mac_hex);
        bad[3] = (bad[3] == '0') ? '1' : '0';   /* 翻一位 */
        CHECK(pam_verify_response(key, nonce, v->user, v->service, good) == 1, "good mac accepted");
        CHECK(pam_verify_response(key, nonce, v->user, v->service, bad) == 0, "bad mac rejected");
        CHECK(pam_verify_response(key, nonce, v->user, v->service, "OK") == 0, "bare OK rejected");
        CHECK(pam_verify_response(key, nonce, v->user, "sudo_local", good) == 0, "service bound");
        CHECK(pam_verify_response(key, nonce, "mallory", v->service, good) == 0, "user bound");
        CHECK(pam_verify_response(key, nonce, v->user, v->service, "OK:zz") == 0, "short hex rejected");
    }
}

static void test_hex_and_nonce(void) {
    uint8_t n1[16], n2[16];
    pam_gen_nonce(n1);
    pam_gen_nonce(n2);
    CHECK(memcmp(n1, n2, 16) != 0, "nonce not repeated");
    char hex[33];
    uint8_t b[2] = {0xde, 0xad};
    pam_hex(b, 2, hex);
    CHECK(strcmp(hex, "dead") == 0, "hex lower");
}

static void test_load_key_modes(void) {
    char dir[] = "/tmp/pamkeytest.XXXXXX";
    CHECK(mkdtemp(dir) != NULL, "mkdtemp");
    uid_t me = getuid();
    char path[256];
    uint8_t key[32], out[32];
    unhex(PAM_VECS[0].key_hex, key, 32);

    /* 不存在 → 0 */
    CHECK(pam_load_key(dir, me, out) == 0, "missing key → compat");

    /* 0600 且 32 字节 → 1。测试进程不是 root，所以属主检查用 geteuid()==0 时才要求 uid 0，
       非 root 测试环境下要求属主 == 当前 euid。 */
    snprintf(path, sizeof path, "%s/%u.key", dir, (unsigned)me);
    write_file(path, key, 32, 0600);
    CHECK(pam_load_key(dir, me, out) == 1, "0600 key loaded");
    CHECK(memcmp(out, key, 32) == 0, "key bytes");

    /* 0644 → -1 */
    chmod(path, 0644);
    CHECK(pam_load_key(dir, me, out) == -1, "group/other readable rejected");

    /* 长度错 → -1 */
    write_file(path, key, 31, 0600);
    CHECK(pam_load_key(dir, me, out) == -1, "wrong length rejected");

    /* 符号链接 → -1 */
    unlink(path);
    char target[256];
    snprintf(target, sizeof target, "%s/real.key", dir);
    write_file(target, key, 32, 0600);
    symlink(target, path);
    CHECK(pam_load_key(dir, me, out) == -1, "symlink rejected");

    unlink(path); unlink(target); rmdir(dir);
}

static int count_lines(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int lines = 0;
    int c;
    while ((c = fgetc(f)) != EOF) if (c == '\n') lines++;
    fclose(f);
    return lines;
}

static void test_audit_log(void) {
    char dir[] = "/tmp/pamaudittest.XXXXXX";
    CHECK(mkdtemp(dir) != NULL, "mkdtemp");
    char path[300];
    snprintf(path, sizeof path, "%s/immurok-pam.log", dir);

    pam_audit_log_to(path, "alice", "sudo", "MAC_MISMATCH");
    pam_audit_log_to(path, "alice", "sudo", "MAC_MISMATCH");

    CHECK(count_lines(path) == 2, "audit log has 2 lines after 2 calls");

    FILE *f = fopen(path, "r");
    CHECK(f != NULL, "audit log opens for read");
    if (f) {
        char line[256];
        int n = 0;
        while (fgets(line, sizeof line, f)) {
            n++;
            CHECK(strstr(line, "user=alice service=sudo MAC_MISMATCH") != NULL,
                  "audit log line has expected fields");
        }
        CHECK(n == 2, "audit log iterated 2 lines");
        fclose(f);
    }

    struct stat st;
    CHECK(stat(path, &st) == 0, "audit log stat");
    CHECK((st.st_mode & 0777) == 0644, "audit log mode is 0644");

    unlink(path); rmdir(dir);
}

int main(void) {
    test_sha256_known();
    test_hmac_rfc4231_case2();
    test_vectors_mac();
    test_secure_zero();
    test_verify_response_vectors();
    test_hex_and_nonce();
    test_load_key_modes();
    test_audit_log();
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("all tests passed\n");
    return 0;
}
