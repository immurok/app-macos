/* 内嵌 SHA-256 / HMAC-SHA256。PAM 模块不能依赖 OpenSSL 或 CommonCrypto。 */
#pragma once
#include <stdint.h>
#include <stddef.h>

/* 安全清除内存，编译器不会将其优化删除 */
void secure_zero(void *p, size_t n);

void sha256(const uint8_t *data, size_t len, uint8_t out[32]);
void hmac_sha256(const uint8_t *key, size_t key_len,
                 const uint8_t *data, size_t len, uint8_t out[32]);
