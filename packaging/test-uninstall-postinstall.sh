#!/bin/bash
# 在临时目录用伪造的根目录测试 uninstall-postinstall 的 pam.d 部分：
# 正常卸载清掉 pam.d 行并删文件；TCC 被拒（只读文件模拟）时恢复 pam.d、
# 非 0 退出且一个文件都不删。IMMUROK_ROOT 非空时脚本跳过 killall/pkgutil 等系统命令。
# 用法: bash test-uninstall-postinstall.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNINST="$SCRIPT_DIR/uninstall-postinstall"
FAILS=0
LINE="auth sufficient /usr/local/lib/pam/pam_immurok.so"
STOCK_AUTH=$'# authorization: auth account\nauth       required       pam_opendirectory.so use_first_pass nullok\n'

fail() { echo "FAIL[$1]: $2"; FAILS=$((FAILS+1)); }

# 伪根：pam.d 两文件都含 immurok 行 + stock 行；.so / imk / App / 密钥目录 / 用户数据齐全
make_root() {
    local root; root="$(mktemp -d)"
    mkdir -p "$root/etc/pam.d" "$root/usr/local/lib/pam" "$root/usr/local/bin" \
             "$root/Applications/immurok.app" "$root/etc/immurok/pam" "$root/home/.immurok"
    printf '%s\n%s' "$LINE" "$STOCK_AUTH" > "$root/etc/pam.d/authorization"
    printf '%s\n# sudo_local\n' "$LINE" > "$root/etc/pam.d/sudo_local"
    : > "$root/usr/local/lib/pam/pam_immurok.so"
    : > "$root/usr/local/bin/imk"
    : > "$root/Applications/immurok.app/x"
    : > "$root/etc/immurok/pam/501.keyid"
    : > "$root/home/.immurok/x"
    echo "$root"
}
snapshot() { cp "$1/etc/pam.d/$2" "$1/orig.$2"; }
same_as_snapshot() { cmp -s "$1/etc/pam.d/$2" "$1/orig.$2"; }
all_present() {  # $1=root $2=用例名
    local p
    for p in usr/local/lib/pam/pam_immurok.so usr/local/bin/imk Applications/immurok.app etc/immurok home/.immurok; do
        [ -e "$1/$p" ] || fail "$2" "$p 被删除了（被拒时不应删任何东西）"
    done
}
cleanup() { chmod -R u+w "$1" 2>/dev/null; rm -rf "$1"; }

# ---- ok：全可写 → exit 0，pam.d 行移除且 stock 行保留，文件全删 ----
ROOT="$(make_root)"
IMMUROK_ROOT="$ROOT" bash "$UNINST" >"$ROOT/out.log" 2>"$ROOT/err.log"; RC=$?
[ $RC -eq 0 ] || fail ok "exit ${RC}（应为 0）"
grep -q pam_immurok "$ROOT/etc/pam.d/authorization" && fail ok "authorization 仍含 pam_immurok"
grep -q pam_opendirectory "$ROOT/etc/pam.d/authorization" || fail ok "authorization 的 stock 行丢失"
grep -q pam_immurok "$ROOT/etc/pam.d/sudo_local" && fail ok "sudo_local 仍含 pam_immurok"
for p in usr/local/bin/imk Applications/immurok.app etc/immurok home/.immurok; do
    [ ! -e "$ROOT/$p" ] || fail ok "$p 应被删除"
done
# 模块永远不删：留一个文件无害，删了而 pam.d 还有引用则 sudo/授权全坏
[ -e "$ROOT/usr/local/lib/pam/pam_immurok.so" ] || fail ok "pam_immurok.so 被删除了（卸载不应删模块）"
cleanup "$ROOT"

# ---- deny-keeps-everything：sudo_local 只读 → exit 1，pam.d 不变，什么都不删 ----
ROOT="$(make_root)"
snapshot "$ROOT" authorization; snapshot "$ROOT" sudo_local
chmod 444 "$ROOT/etc/pam.d/sudo_local"
IMMUROK_ROOT="$ROOT" bash "$UNINST" >"$ROOT/out.log" 2>"$ROOT/err.log"; RC=$?
[ $RC -ne 0 ] || fail deny-keeps-everything "被拒时应非 0 退出"
same_as_snapshot "$ROOT" sudo_local || fail deny-keeps-everything "sudo_local 内容被改动"
same_as_snapshot "$ROOT" authorization || fail deny-keeps-everything "authorization 内容被改动"
all_present "$ROOT" deny-keeps-everything
grep -q "uninstall aborted, nothing removed" "$ROOT/err.log" || fail deny-keeps-everything "stderr 缺少 uninstall aborted, nothing removed"
cleanup "$ROOT"

# ---- dir-deny：文件只读且目录只读（unlink 也被拒）→ exit 1、日志行出现、什么都不删 ----
ROOT="$(make_root)"
snapshot "$ROOT" authorization; snapshot "$ROOT" sudo_local
chmod 444 "$ROOT/etc/pam.d/sudo_local"; chmod 555 "$ROOT/etc/pam.d"
IMMUROK_ROOT="$ROOT" bash "$UNINST" >"$ROOT/out.log" 2>"$ROOT/err.log"; RC=$?
[ $RC -ne 0 ] || fail dir-deny "被拒时应非 0 退出"
same_as_snapshot "$ROOT" sudo_local || fail dir-deny "sudo_local 内容被改动"
all_present "$ROOT" dir-deny
grep -q "uninstall aborted, nothing removed" "$ROOT/err.log" || fail dir-deny "stderr 缺少 uninstall aborted, nothing removed"
cleanup "$ROOT"

# ---- partial-deny：sudo_local 可写、authorization 只读 → sudo_local 恢复，什么都不删 ----
ROOT="$(make_root)"
snapshot "$ROOT" authorization; snapshot "$ROOT" sudo_local
chmod 444 "$ROOT/etc/pam.d/authorization"
IMMUROK_ROOT="$ROOT" bash "$UNINST" >"$ROOT/out.log" 2>"$ROOT/err.log"; RC=$?
[ $RC -ne 0 ] || fail partial-deny "被拒时应非 0 退出"
same_as_snapshot "$ROOT" sudo_local || fail partial-deny "sudo_local 未恢复为原内容"
same_as_snapshot "$ROOT" authorization || fail partial-deny "authorization 内容被改动"
all_present "$ROOT" partial-deny
cleanup "$ROOT"

# ---- other-service：用户手动把行加进了别的服务（su）→ 一并撤掉，照常卸载 ----
ROOT="$(make_root)"
printf '%s\nauth       required       pam_opendirectory.so\n' "$LINE" > "$ROOT/etc/pam.d/su"
IMMUROK_ROOT="$ROOT" bash "$UNINST" >"$ROOT/out.log" 2>"$ROOT/err.log"; RC=$?
[ $RC -eq 0 ] || fail other-service "exit ${RC}（应为 0）"
grep -q pam_immurok "$ROOT/etc/pam.d/su" && fail other-service "su 仍含 pam_immurok"
grep -q pam_opendirectory "$ROOT/etc/pam.d/su" || fail other-service "su 的原有行丢失"
[ ! -e "$ROOT/usr/local/bin/imk" ] || fail other-service "imk 应被删除"
[ -e "$ROOT/usr/local/lib/pam/pam_immurok.so" ] || fail other-service "模块不应被删除"
cleanup "$ROOT"

# ---- still-referenced：某文件只有我们这一行（删了会变空，strip_line 不写）→
#      引用还在，模块和其余文件必须全部保留，非 0 退出 ----
ROOT="$(make_root)"
printf '%s\n' "$LINE" > "$ROOT/etc/pam.d/authorization"
IMMUROK_ROOT="$ROOT" bash "$UNINST" >"$ROOT/out.log" 2>"$ROOT/err.log"; RC=$?
[ $RC -ne 0 ] || fail still-referenced "仍有引用时应非 0 退出"
grep -q pam_immurok "$ROOT/etc/pam.d/authorization" || fail still-referenced "用例前提不成立：authorization 的行被删了"
all_present "$ROOT" still-referenced
grep -q "module kept, uninstall aborted" "$ROOT/err.log" || fail still-referenced "stderr 缺少 module kept, uninstall aborted"
cleanup "$ROOT"

# ---- commented-only：只剩被注释掉的引用 → 不算引用，照常卸载 ----
ROOT="$(make_root)"
printf '# %s\nauth       required       pam_opendirectory.so\n' "$LINE" > "$ROOT/etc/pam.d/su"
chmod 444 "$ROOT/etc/pam.d/su"
IMMUROK_ROOT="$ROOT" bash "$UNINST" >"$ROOT/out.log" 2>"$ROOT/err.log"; RC=$?
[ $RC -eq 0 ] || fail commented-only "只剩注释引用时应照常卸载（exit ${RC}）"
[ ! -e "$ROOT/usr/local/bin/imk" ] || fail commented-only "imk 应被删除"
cleanup "$ROOT"

# ---- external-copy：App 包外的卸载包目录一并删除 ----
ROOT="$(make_root)"
mkdir -p "$ROOT/Library/Application Support/immurok"; : > "$ROOT/Library/Application Support/immurok/immurok_uninstall.pkg"
IMMUROK_ROOT="$ROOT" bash "$UNINST" >"$ROOT/out.log" 2>"$ROOT/err.log"; RC=$?
[ ! -e "$ROOT/Library/Application Support/immurok" ] || fail external-copy "Application Support/immurok 应被删除"
cleanup "$ROOT"

if [ $FAILS -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$FAILS FAILURE(S)"; exit 1; fi
