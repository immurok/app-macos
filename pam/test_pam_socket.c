/* Exercise the production authentication path against a private Unix socket.
 * Redirect only identity/key locations and observable system side effects.
 * No installed PAM stack, real user socket, device, Keychain, or root access. */
#define getpwnam fixture_getpwnam
#define pam_load_key fixture_load_key
#define open fixture_open
#define syslog fixture_syslog
#define pam_audit_log_to fixture_audit_log
#include "pam_immurok.c"
#undef getpwnam
#undef pam_load_key
#undef open
#undef syslog
#undef pam_audit_log_to
#include <sys/stat.h>
#include <sys/wait.h>
#include <assert.h>

/* The real loader is compiled separately, without the redirection above. */
int pam_load_key(const char *, uid_t, uint8_t[32]);
static char test_home[80];
static uint8_t provisioned[32];
struct passwd *fixture_getpwnam(const char *name) {
    static struct passwd pw;
    (void)name; pw.pw_uid = getuid(); pw.pw_dir = test_home;
    return &pw;
}
int fixture_load_key(const char *dir, uid_t uid, uint8_t key[32]) {
    (void)dir; return pam_load_key(test_home, uid, key);
}
int fixture_open(const char *path, int flags, ...) {
    (void)flags; assert(strcmp(path, "/dev/tty") == 0);
    errno = ENXIO; return -1;
}
void fixture_syslog(int priority, const char *format, ...) {
    (void)priority; (void)format;
}
void fixture_audit_log(const char *path, const char *user,
                       const char *service, const char *reason) {
    (void)path; (void)user; (void)service; (void)reason;
}
static void write_key(const char *path, size_t size) {
    FILE *f = fopen(path, "wb"); assert(f);
    assert(fwrite(provisioned, 1, size, f) == size);
    assert(fclose(f) == 0); assert(chmod(path, 0600) == 0);
}
static void assert_no_connection(int listener) {
    fd_set fds; FD_ZERO(&fds); FD_SET(listener, &fds);
    struct timeval timeout = {0, 20000};
    assert(select(listener + 1, &fds, NULL, NULL, &timeout) == 0);
}
enum reply_kind { BARE_OK, WRONG_KEY, STALE_NONCE, VALID_MAC };
static void exchange(int listener, enum reply_kind kind, int expected) {
    pid_t child = fork(); assert(child >= 0);
    if (child == 0) {
        alarm(5);
        int fd = accept(listener, NULL, NULL); assert(fd >= 0);
        char request[256] = {0}; size_t used = 0;
        /* This fixture's production request is AUTH:review:custom-service:<nonce>. */
        const char *prefix = "AUTH:review:custom-service:";
        size_t wanted = strlen(prefix) + PAM_NONCE_LEN * 2;
        while (used < wanted) {
            ssize_t n = recv(fd, request + used, wanted - used, 0);
            assert(n > 0); used += (size_t)n;
        }
        assert(strncmp(request, prefix, strlen(prefix)) == 0);
        uint8_t nonce[PAM_NONCE_LEN], mac[PAM_MAC_LEN], signing_key[32];
        const char *hex = request + strlen(prefix);
        for (size_t i = 0; i < sizeof nonce; i++) {
            unsigned value; assert(sscanf(hex + i * 2, "%2x", &value) == 1);
            nonce[i] = (uint8_t)value;
        }
        memcpy(signing_key, provisioned, 32);
        if (kind == WRONG_KEY) signing_key[0] ^= 1;
        if (kind == STALE_NONCE) nonce[0] ^= 1;
        char response[3 + PAM_MAC_LEN * 2 + 1] = "OK";
        if (kind != BARE_OK) {
            assert(pam_compute_mac(signing_key, nonce, "review", "custom-service", mac) == 0);
            memcpy(response, "OK:", 3); pam_hex(mac, PAM_MAC_LEN, response + 3);
        }
        assert(send(fd, response, strlen(response), 0) == (ssize_t)strlen(response));
        close(fd); _exit(0);
    }
    assert(authenticate_via_socket("review", "custom-service") == expected);
    int status; assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}
int main(void) {
    alarm(30);
    strcpy(test_home, "/tmp/imk-socket-review.XXXXXX"); assert(mkdtemp(test_home));
    char dir[100], path[110], keypath[110], target[110];
    snprintf(dir, sizeof dir, "%s/.immurok", test_home); assert(mkdir(dir, 0700) == 0);
    snprintf(path, sizeof path, "%s/pam.sock", dir);
    snprintf(keypath, sizeof keypath, "%s/%u.key", test_home, (unsigned)getuid());
    snprintf(target, sizeof target, "%s/target.key", test_home);
    int listener = socket(AF_UNIX, SOCK_STREAM, 0); assert(listener >= 0);
    struct sockaddr_un addr = {0}; addr.sun_family = AF_UNIX;
    assert(strlen(path) < sizeof addr.sun_path); strcpy(addr.sun_path, path);
    assert(bind(listener, (struct sockaddr *)&addr, sizeof addr) == 0);
    assert(listen(listener, 1) == 0);
    memset(provisioned, 0x42, sizeof provisioned);
    /* A spoof listener exists even when no key can be trusted. */
    assert(authenticate_via_socket("review", "custom-service") == PAM_IGNORE);
    assert_no_connection(listener);
    write_key(keypath, 31);
    assert(authenticate_via_socket("review", "custom-service") == PAM_IGNORE);
    assert_no_connection(listener);
    assert(unlink(keypath) == 0); write_key(target, 32);
    assert(symlink(target, keypath) == 0);
    assert(authenticate_via_socket("review", "custom-service") == PAM_IGNORE);
    assert_no_connection(listener); assert(unlink(keypath) == 0);
    write_key(keypath, 32);
    assert(chmod(keypath, 0644) == 0);
    assert(authenticate_via_socket("review", "custom-service") == PAM_IGNORE);
    assert_no_connection(listener); assert(chmod(keypath, 0600) == 0);
    exchange(listener, BARE_OK, PAM_AUTH_ERR);
    exchange(listener, WRONG_KEY, PAM_AUTH_ERR);
    exchange(listener, STALE_NONCE, PAM_AUTH_ERR);
    exchange(listener, VALID_MAC, PAM_SUCCESS);
    close(listener); unlink(path); unlink(keypath); unlink(target); rmdir(dir); rmdir(test_home);
    puts("PAM isolated socket integration tests passed");
    return 0;
}
