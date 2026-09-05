#!/usr/bin/env python3
"""生成 PAM 信道 MAC 测试向量。三端（macOS Swift / Linux Rust / PAM C）共用。

    mac    = HMAC-SHA256(pam_key, "immurok-pam-v1" || nonce[16] || user || 0 || service || 0)[0:16]
    key_id = SHA256(pam_key)[0:8]
"""
import hashlib, hmac, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
PREFIX = b"immurok-pam-v1"

CASES = [
    (bytes(range(32)), bytes(range(0xA0, 0xB0)), "alice", "sudo"),
    (b"\xff" * 32, b"\x00" * 16, "bob", "authorization"),
    (hashlib.sha256(b"immurok-test-key-3").digest(),
     hashlib.sha256(b"immurok-test-nonce-3").digest()[:16], "carol", "auth-gui"),
]

def mac(key, nonce, user, service):
    msg = PREFIX + nonce + user.encode() + b"\x00" + service.encode() + b"\x00"
    return hmac.new(key, msg, hashlib.sha256).digest()[:16]

vectors = []
for key, nonce, user, service in CASES:
    vectors.append({
        "key": key.hex(), "nonce": nonce.hex(), "user": user, "service": service,
        "key_id": hashlib.sha256(key).digest()[:8].hex(),
        "mac": mac(key, nonce, user, service).hex(),
    })

os.makedirs(os.path.join(HERE, "vectors"), exist_ok=True)
with open(os.path.join(HERE, "vectors", "pam-mac-v1.json"), "w") as f:
    json.dump({"version": 1, "prefix": PREFIX.decode(), "vectors": vectors}, f, indent=2)
    f.write("\n")

with open(os.path.join(HERE, "test_vectors.h"), "w") as f:
    f.write("/* 由 gen_vectors.py 生成，勿手改 */\n#pragma once\n")
    f.write("#define PAM_VEC_COUNT %d\n" % len(vectors))
    f.write("struct pam_vec { const char *key_hex, *nonce_hex, *user, *service, *key_id, *mac_hex; };\n")
    f.write("static const struct pam_vec PAM_VECS[PAM_VEC_COUNT] = {\n")
    for v in vectors:
        f.write('    {"%s", "%s", "%s", "%s", "%s", "%s"},\n' % (
            v["key"], v["nonce"], v["user"], v["service"], v["key_id"], v["mac"]))
    f.write("};\n")
print("ok:", len(vectors), "vectors")
