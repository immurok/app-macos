/* PAM 信道 MAC：密钥文件、nonce、MAC 计算与验证。不依赖 PAM 头，可单独测试。 */
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

#define PAM_KEY_DIR_DEFAULT "/etc/immurok/pam"
#define PAM_NONCE_LEN 16
#define PAM_MAC_LEN 16
#define PAM_AUDIT_LOG_PATH "/var/log/immurok-pam.log"

/* 返回 1=已读到强认证密钥，0=文件不存在（兼容模式），-1=文件存在但不合规（按 0 处理，调用方记 syslog）。 */
int pam_load_key(const char *dir, uid_t uid, uint8_t key[32]);
void pam_gen_nonce(uint8_t nonce[PAM_NONCE_LEN]);
void pam_hex(const uint8_t *in, size_t n, char *out);          /* out 需要 2n+1 字节 */
int pam_compute_mac(const uint8_t key[32], const uint8_t nonce[PAM_NONCE_LEN],
                    const char *user, const char *service, uint8_t mac[PAM_MAC_LEN]);
/* 解析 "OK:<hex32>" 并常量时间比较。1=通过，0=不通过。 */
int pam_verify_response(const uint8_t key[32], const uint8_t nonce[PAM_NONCE_LEN],
                        const char *user, const char *service, const char *response);

/* 追加一行审计记录到 path（生产环境固定用 PAM_AUDIT_LOG_PATH，root 0644：内容不含
 * 秘密，普通用户可读以便脚本断言；O_APPEND|O_CREAT|O_NOFOLLOW）。打开失败（含非 root
 * 进程对已存在的 root-owned 0644 文件无写权限的情况）时静默返回，绝不影响认证结果。
 * 格式：2026-09-03T12:17:50+0800 pid=36505 user=katsu service=sudo MAC_MISMATCH
 * path 参数化是为了让单测能指向 mkdtemp 临时文件而不必依赖真实 /var/log 路径。 */
void pam_audit_log_to(const char *path, const char *user, const char *service, const char *reason);
static inline void pam_audit_log(const char *user, const char *service, const char *reason) {
    pam_audit_log_to(PAM_AUDIT_LOG_PATH, user, service, reason);
}
