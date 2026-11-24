/* Exercise the actual PAM entry path without touching the system PAM stack,
 * user sockets, Keychain or /var/log. Crypto tests run separately. */
#define pam_load_key fixture_load_key
#define socket fixture_socket
#define pam_audit_log_to fixture_audit_log
#include "pam_immurok.c"
#undef pam_load_key
#undef socket
#undef pam_audit_log_to

static int key_result;
static int socket_calls;
int fixture_load_key(const char *dir, uid_t uid, uint8_t key[32]) {
    (void)dir; (void)uid;
    memset(key, 0x42, 32);
    return key_result;
}
int fixture_socket(int domain, int type, int protocol) {
    (void)domain; (void)type; (void)protocol;
    socket_calls++;
    errno = ECONNREFUSED;
    return -1;
}
void fixture_audit_log(const char *path, const char *user, const char *service, const char *reason) {
    (void)path; (void)user; (void)service; (void)reason;
}
int main(void) {
    struct passwd *pw = getpwuid(getuid());
    if (!pw) return 2;
    for (int state = -1; state <= 1; state++) {
        key_result = state;
        socket_calls = 0;
        int rc = authenticate_via_socket(pw->pw_name, "sudo");
        if (state != 1 && (rc != PAM_IGNORE || socket_calls != 0)) {
            fprintf(stderr, "FAIL: missing/unusable key contacted an untrusted socket\n");
            return 1;
        }
        if (state == 1 && (rc != PAM_AUTH_ERR || socket_calls != 1)) {
            fprintf(stderr, "FAIL: provisioned key did not enter authenticated transport\n");
            return 1;
        }
    }
    puts("PAM fail-closed policy tests passed");
    return 0;
}
