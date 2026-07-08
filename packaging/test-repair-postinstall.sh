#!/bin/bash
# 在临时目录用伪造的 pam.d 文件测试 repair-postinstall 的幂等性。
# 用法: bash test-repair-postinstall.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPAIR="$SCRIPT_DIR/repair-postinstall"
LINE="auth sufficient /usr/local/lib/pam/pam_immurok.so"
FAILS=0

run_case() {
    local name="$1" auth_seed="$2" sudo_seed="$3"
    local root; root="$(mktemp -d)"
    mkdir -p "$root/etc/pam.d" "$root/usr/local/lib/pam"
    : > "$root/usr/local/lib/pam/pam_immurok.so"            # .so 存在
    if [ "$auth_seed" = "__ABSENT__" ]; then
        rm -f "$root/etc/pam.d/authorization"
    else
        printf '%s' "$auth_seed" > "$root/etc/pam.d/authorization"
    fi
    if [ "$sudo_seed" = "__ABSENT__" ]; then
        rm -f "$root/etc/pam.d/sudo_local"
    else
        printf '%s' "$sudo_seed" > "$root/etc/pam.d/sudo_local"
    fi
    IMMUROK_ROOT="$root" bash "$REPAIR" >/dev/null 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then echo "FAIL[$name]: exit $rc"; FAILS=$((FAILS+1)); rm -rf "$root"; return; fi
    if ! grep -q pam_immurok "$root/etc/pam.d/authorization"; then
        echo "FAIL[$name]: authorization 缺 pam_immurok 行"; FAILS=$((FAILS+1))
    fi
    local count; count=$(grep -c pam_immurok "$root/etc/pam.d/authorization")
    if [ "$count" -ne 1 ]; then echo "FAIL[$name]: authorization 出现 $count 次(应为 1)"; FAILS=$((FAILS+1)); fi
    if ! grep -q pam_immurok "$root/etc/pam.d/sudo_local"; then
        echo "FAIL[$name]: sudo_local 缺 pam_immurok 行"; FAILS=$((FAILS+1))
    fi
    local scount; scount=$(grep -c pam_immurok "$root/etc/pam.d/sudo_local")
    if [ "$scount" -ne 1 ]; then echo "FAIL[$name]: sudo_local 出现 $scount 次(应为 1)"; FAILS=$((FAILS+1)); fi
    # 原始内容保留断言
    if printf '%s' "$auth_seed" | grep -q pam_opendirectory; then
        if ! grep -q pam_opendirectory "$root/etc/pam.d/authorization"; then
            echo "FAIL[$name]: 原始 pam_opendirectory.so 行丢失"; FAILS=$((FAILS+1))
        fi
    fi
    # 二次运行幂等
    IMMUROK_ROOT="$root" bash "$REPAIR" >/dev/null 2>&1
    local count2; count2=$(grep -c pam_immurok "$root/etc/pam.d/authorization")
    if [ "$count2" -ne 1 ]; then echo "FAIL[$name]: 二次运行后 authorization 出现 $count2 次(应为 1)"; FAILS=$((FAILS+1)); fi
    rm -rf "$root"
}

# authorization 缺行 / sudo_local 缺行(升级重置场景)
run_case "both-missing" $'# stock\nauth required pam_opendirectory.so\n' $'auth include foo\n'
# authorization 已有行(幂等)
run_case "auth-present" "$LINE"$'\n# stock\n' $'auth include foo\n'
# sudo_local 文件不存在(应创建)
run_case "sudo-absent" $'# stock\n' "__ABSENT__"
# authorization 文件不存在(应创建)
run_case "auth-absent" "__ABSENT__" $'auth include foo\n'

# ---- macOS 13.x 分支: pam 行直写 /etc/pam.d/sudo ----
STOCK_SUDO=$'# sudo: auth account\nauth       sufficient     pam_smartcard.so\nauth       required       pam_opendirectory.so\n'

make_root() {
    local root; root="$(mktemp -d)"
    mkdir -p "$root/etc/pam.d" "$root/usr/local/lib/pam"
    : > "$root/usr/local/lib/pam/pam_immurok.so"
    printf '# stock\n' > "$root/etc/pam.d/authorization"
    printf 'auth include foo\n' > "$root/etc/pam.d/sudo_local"
    echo "$root"
}

# 13.x + sudo 文件存在 → 补行,幂等,原始行保留
ROOT3="$(make_root)"
printf '%s' "$STOCK_SUDO" > "$ROOT3/etc/pam.d/sudo"
IMMUROK_ROOT="$ROOT3" IMMUROK_OS_MAJOR=13 bash "$REPAIR" >/dev/null 2>&1
if ! grep -q pam_immurok "$ROOT3/etc/pam.d/sudo"; then
    echo "FAIL[legacy-sudo]: /etc/pam.d/sudo 缺 pam_immurok 行"; FAILS=$((FAILS+1))
fi
if ! grep -q pam_opendirectory "$ROOT3/etc/pam.d/sudo"; then
    echo "FAIL[legacy-sudo]: 原始 pam_opendirectory 行丢失"; FAILS=$((FAILS+1))
fi
IMMUROK_ROOT="$ROOT3" IMMUROK_OS_MAJOR=13 bash "$REPAIR" >/dev/null 2>&1
LCOUNT=$(grep -c pam_immurok "$ROOT3/etc/pam.d/sudo")
if [ "$LCOUNT" -ne 1 ]; then echo "FAIL[legacy-sudo]: 二次运行后出现 $LCOUNT 次(应为 1)"; FAILS=$((FAILS+1)); fi
rm -rf "$ROOT3"

# 14+ → 不碰 /etc/pam.d/sudo
ROOT4="$(make_root)"
printf '%s' "$STOCK_SUDO" > "$ROOT4/etc/pam.d/sudo"
IMMUROK_ROOT="$ROOT4" IMMUROK_OS_MAJOR=14 bash "$REPAIR" >/dev/null 2>&1
if grep -q pam_immurok "$ROOT4/etc/pam.d/sudo"; then
    echo "FAIL[modern-sudo]: 14+ 不应写 /etc/pam.d/sudo"; FAILS=$((FAILS+1))
fi
rm -rf "$ROOT4"

# 13.x + sudo 文件不存在 → 跳过且不创建(裸文件会弄坏 sudo),退出 0
ROOT5="$(make_root)"
IMMUROK_ROOT="$ROOT5" IMMUROK_OS_MAJOR=13 bash "$REPAIR" >/dev/null 2>&1
RC5=$?
if [ $RC5 -ne 0 ]; then echo "FAIL[legacy-no-sudo]: exit $RC5(应为 0)"; FAILS=$((FAILS+1)); fi
if [ -f "$ROOT5/etc/pam.d/sudo" ]; then
    echo "FAIL[legacy-no-sudo]: 不应凭空创建 /etc/pam.d/sudo"; FAILS=$((FAILS+1))
fi
rm -rf "$ROOT5"

# .so 不存在 → 应非 0 退出
ROOT2="$(mktemp -d)"; mkdir -p "$ROOT2/etc/pam.d"
printf '# stock\n' > "$ROOT2/etc/pam.d/authorization"
IMMUROK_ROOT="$ROOT2" bash "$REPAIR" >/dev/null 2>&1
if [ $? -eq 0 ]; then echo "FAIL[no-so]: .so 缺失时应非 0 退出"; FAILS=$((FAILS+1)); fi
rm -rf "$ROOT2"

if [ $FAILS -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$FAILS FAILURE(S)"; exit 1; fi
