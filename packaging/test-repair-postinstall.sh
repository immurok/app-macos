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

# .so 不存在 → 应非 0 退出
ROOT2="$(mktemp -d)"; mkdir -p "$ROOT2/etc/pam.d"
printf '# stock\n' > "$ROOT2/etc/pam.d/authorization"
IMMUROK_ROOT="$ROOT2" bash "$REPAIR" >/dev/null 2>&1
if [ $? -eq 0 ]; then echo "FAIL[no-so]: .so 缺失时应非 0 退出"; FAILS=$((FAILS+1)); fi
rm -rf "$ROOT2"

if [ $FAILS -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$FAILS FAILURE(S)"; exit 1; fi
