#!/bin/bash
# 在临时目录用伪造的根目录测试主安装包 postinstall：
# 正常写入 / 幂等 / TCC 被拒（以只读文件、只读目录模拟 Operation not permitted）时
# 恢复原状且仍 exit 0（安装继续，由 App 提示修复）。
# 用法: bash test-postinstall.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POST="$SCRIPT_DIR/postinstall"
FAILS=0

STOCK_AUTH=$'# authorization: auth account\nauth       required       pam_opendirectory.so use_first_pass nullok\n'
STOCK_SUDO=$'# sudo: auth account\nauth       sufficient     pam_smartcard.so\nauth       required       pam_opendirectory.so\n'
SEED_SUDO_LOCAL=$'auth include foo\n'
DENIED_MSG='write denied (TCC), install continues'

fail() { echo "FAIL[$1]: $2"; FAILS=$((FAILS+1)); }

# 伪根：.so / imk / App 目录齐全，authorization 为 stock 内容，sudo_local 由用例决定
make_root() {
    local root; root="$(mktemp -d)"
    mkdir -p "$root/etc/pam.d" "$root/usr/local/lib/pam" "$root/usr/local/bin" "$root/Applications/immurok.app"
    : > "$root/usr/local/lib/pam/pam_immurok.so"
    : > "$root/usr/local/bin/imk"
    printf '%s' "$STOCK_AUTH" > "$root/etc/pam.d/authorization"
    echo "$root"
}
snapshot() { cp "$1/etc/pam.d/$2" "$1/orig.$2"; }
same_as_snapshot() { cmp -s "$1/etc/pam.d/$2" "$1/orig.$2"; }
run_post() {  # $1=root $2=os major
    IMMUROK_ROOT="$1" IMMUROK_OS_MAJOR="$2" bash "$POST" >"$1/out.log" 2>"$1/err.log"
}
cleanup() { chmod -R u+w "$1" 2>/dev/null; rm -rf "$1"; }

# ---- fresh：sudo_local 不存在 → 两文件各 1 行，stock 行保留，二次运行幂等 ----
ROOT="$(make_root)"
run_post "$ROOT" 15; RC=$?
[ $RC -eq 0 ] || fail fresh "exit ${RC}（应为 0）"
[ "$(grep -c pam_immurok "$ROOT/etc/pam.d/authorization")" = 1 ] || fail fresh "authorization 应含 1 行 pam_immurok"
[ "$(grep -c pam_immurok "$ROOT/etc/pam.d/sudo_local")" = 1 ] || fail fresh "sudo_local 应含 1 行 pam_immurok"
grep -q pam_opendirectory "$ROOT/etc/pam.d/authorization" || fail fresh "原 pam_opendirectory 行丢失"
run_post "$ROOT" 15
[ "$(grep -c pam_immurok "$ROOT/etc/pam.d/authorization")" = 1 ] || fail fresh "二次运行后 authorization 行数不为 1"
[ "$(grep -c pam_immurok "$ROOT/etc/pam.d/sudo_local")" = 1 ] || fail fresh "二次运行后 sudo_local 行数不为 1"
cleanup "$ROOT"

# ---- all-deny：两文件都只读 → exit 0，内容逐字节不变，stderr 有明确日志 ----
ROOT="$(make_root)"
printf '%s' "$SEED_SUDO_LOCAL" > "$ROOT/etc/pam.d/sudo_local"
snapshot "$ROOT" authorization; snapshot "$ROOT" sudo_local
chmod 444 "$ROOT/etc/pam.d/authorization" "$ROOT/etc/pam.d/sudo_local"
run_post "$ROOT" 15; RC=$?
[ $RC -eq 0 ] || fail all-deny "exit ${RC}（应为 0）"
same_as_snapshot "$ROOT" authorization || fail all-deny "authorization 内容被改动"
same_as_snapshot "$ROOT" sudo_local || fail all-deny "sudo_local 内容被改动"
grep -q "$DENIED_MSG" "$ROOT/err.log" || fail all-deny "stderr 缺少「${DENIED_MSG}」"
cleanup "$ROOT"

# ---- dir-deny：文件只读且目录只读（unlink 也被拒，贴近真实 TCC）→ 仍 exit 0，内容不变，有日志 ----
ROOT="$(make_root)"
printf '%s' "$SEED_SUDO_LOCAL" > "$ROOT/etc/pam.d/sudo_local"
snapshot "$ROOT" authorization; snapshot "$ROOT" sudo_local
chmod 444 "$ROOT/etc/pam.d/authorization" "$ROOT/etc/pam.d/sudo_local"
chmod 555 "$ROOT/etc/pam.d"
run_post "$ROOT" 15; RC=$?
[ $RC -eq 0 ] || fail dir-deny "exit ${RC}（应为 0）"
same_as_snapshot "$ROOT" authorization || fail dir-deny "authorization 内容被改动"
same_as_snapshot "$ROOT" sudo_local || fail dir-deny "sudo_local 内容被改动"
grep -q "$DENIED_MSG" "$ROOT/err.log" || fail dir-deny "stderr 缺少「${DENIED_MSG}」"
cleanup "$ROOT"

# ---- partial-deny：sudo_local 可写、authorization 只读 → sudo_local 恢复原样 ----
ROOT="$(make_root)"
printf '%s' "$SEED_SUDO_LOCAL" > "$ROOT/etc/pam.d/sudo_local"
snapshot "$ROOT" authorization; snapshot "$ROOT" sudo_local
chmod 444 "$ROOT/etc/pam.d/authorization"
run_post "$ROOT" 15; RC=$?
[ $RC -eq 0 ] || fail partial-deny "exit ${RC}（应为 0）"
same_as_snapshot "$ROOT" sudo_local || fail partial-deny "sudo_local 未恢复为原内容"
same_as_snapshot "$ROOT" authorization || fail partial-deny "authorization 内容被改动"
cleanup "$ROOT"

# ---- create-deny：sudo_local 不存在且目录只读 → 不留空文件 ----
ROOT="$(make_root)"
snapshot "$ROOT" authorization
chmod 555 "$ROOT/etc/pam.d"
run_post "$ROOT" 15; RC=$?
[ $RC -eq 0 ] || fail create-deny "exit ${RC}（应为 0）"
[ ! -e "$ROOT/etc/pam.d/sudo_local" ] || fail create-deny "不应留下 sudo_local"
same_as_snapshot "$ROOT" authorization || fail create-deny "authorization 内容被改动"
cleanup "$ROOT"

# ---- legacy-deny：13.x，/etc/pam.d/sudo 只读，其余可写 → 整体恢复 ----
ROOT="$(make_root)"
printf '%s' "$SEED_SUDO_LOCAL" > "$ROOT/etc/pam.d/sudo_local"
printf '%s' "$STOCK_SUDO" > "$ROOT/etc/pam.d/sudo"
snapshot "$ROOT" authorization; snapshot "$ROOT" sudo_local; snapshot "$ROOT" sudo
chmod 444 "$ROOT/etc/pam.d/sudo"
run_post "$ROOT" 13; RC=$?
[ $RC -eq 0 ] || fail legacy-deny "exit ${RC}（应为 0）"
same_as_snapshot "$ROOT" sudo || fail legacy-deny "sudo 内容被改动"
same_as_snapshot "$ROOT" sudo_local || fail legacy-deny "sudo_local 未恢复为原内容"
same_as_snapshot "$ROOT" authorization || fail legacy-deny "authorization 内容被改动"
cleanup "$ROOT"

# ---- no-so：模块文件缺失 → 非 0 退出 ----
ROOT="$(make_root)"
rm -f "$ROOT/usr/local/lib/pam/pam_immurok.so"
run_post "$ROOT" 15; RC=$?
[ $RC -ne 0 ] || fail no-so ".so 缺失时应非 0 退出"
cleanup "$ROOT"

if [ $FAILS -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$FAILS FAILURE(S)"; exit 1; fi
