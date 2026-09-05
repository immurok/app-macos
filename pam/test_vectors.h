/* 由 gen_vectors.py 生成，勿手改 */
#pragma once
#define PAM_VEC_COUNT 3
struct pam_vec { const char *key_hex, *nonce_hex, *user, *service, *key_id, *mac_hex; };
static const struct pam_vec PAM_VECS[PAM_VEC_COUNT] = {
    {"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf", "alice", "sudo", "630dcd2966c43366", "f69f1a9e50e440d5b2c9a4d55d6d2ade"},
    {"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "00000000000000000000000000000000", "bob", "authorization", "af9613760f72635f", "7960a35a6ce7ec99ec82534a6c7a63a7"},
    {"f4aa18a1baa99ea6db4f6cf79be86353b1e26e9854064733d6af6b22821dc8ea", "df24f705a507876aa847f6027ee46a70", "carol", "auth-gui", "a209d19acd526cdb", "186999b14638ed7a68a9fa971716118c"},
};
