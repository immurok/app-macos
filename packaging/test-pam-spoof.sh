#!/bin/zsh
# 攻击复现：以本用户身份伪造 ~/.immurok/pam.sock 回复，验证 pam_immurok 在强认证
# 模式下拒绝并退回密码，同时把拒绝原因记进 /var/log/immurok-pam.log。
# 需要 App 已安装、pam_key 已 install（sudo imk pam-key install）。
#
# 用法：packaging/test-pam-spoof.sh
# 会退出 immurok.app 抢占 socket，结束时自动重新打开 App。
#
# 背景（controller 真机验证发现的两个坑，见 task-7-supplement.md）：
# - sudo -n 在无缓存凭据、非交互模式下根本不会进 PAM 链（0 秒返回
#   "a password is required"），brief 原来用 -n 断言是错的。这里改用
#   `sudo -S true </dev/null`：密码从 stdin 读，读到 EOF 直接失败，
#   这样 sudo 才会真的走 PAM 认证链、调用到 pam_immurok。
# - pam_immurok 的 syslog 条目在 unified log 里被 logd 解析成
#   `<compose failure [UUID]>`（第三方 dlopen 模块，logd 拿不到格式串），
#   `log show` 里看不到消息文本。改断言 /var/log/immurok-pam.log 里的
#   审计行，而不是 log show。另外 zsh 内建 log 会遮蔽 /usr/bin/log，
#   本脚本不再需要用到 log/log show。
set -u

SOCK="$HOME/.immurok/pam.sock"
AUDIT_LOG="/var/log/immurok-pam.log"
SPOOF_PY="$(mktemp "${TMPDIR:-/tmp}/pam_spoof_server.XXXXXX")"
mv "$SPOOF_PY" "$SPOOF_PY.py"
SPOOF_PY="$SPOOF_PY.py"

# 伪造服务端的后台 pid，供 cleanup 在异常中断时兜底 kill。
SRV_PID=""
# 只有真的确认 immurok.app 退出、我们自己抢占了 $SOCK 之后才置 1。
# cleanup 用它决定要不要碰 socket / 重新拉起 App——如果 App 从未退出
# （见下面 [1/4] 的检查失败分支），$SOCK 还是那个活着的 App 在用的真实
# socket，trap 绝不能替它 rm 掉。
APP_STOPPED=0

cleanup() {
  local rc=$?
  if [[ -n "$SRV_PID" ]]; then
    kill "$SRV_PID" 2>/dev/null
    wait "$SRV_PID" 2>/dev/null
    SRV_PID=""
  fi
  rm -f "$SPOOF_PY"

  if (( APP_STOPPED )); then
    rm -f "$SOCK"
    echo "重新打开 immurok.app"
    open -a immurok
    local i
    for i in {1..25}; do
      pgrep -xq immurok && break
      sleep 0.2
    done
    pgrep -xq immurok || echo "immurok.app 未能重新启动，请手动打开"
  fi

  exit "$rc"
}
trap cleanup EXIT INT TERM

if ! imk pam-key status >/dev/null; then
  echo "pam_key 未启用，先 sudo imk pam-key install"
  exit 2
fi

# 伪造 pam.sock 服务端：bind -> accept -> recv -> sendall(reply) -> 保持连接
# 直到对端（pam_immurok）关闭。用 Python 而不是 `printf | nc -lU`：nc 在
# stdin 到 EOF 后不保证已写的数据真的发送出去，会导致伪造回复偶发收不到。
cat > "$SPOOF_PY" <<'PYEOF'
import os
import socket
import sys

sock_path, reply = sys.argv[1], sys.argv[2]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(1)
conn, _ = srv.accept()
try:
    conn.recv(4096)
    conn.sendall(reply.encode())
    while conn.recv(4096):
        pass
finally:
    conn.close()
    srv.close()
PYEOF

echo "[1/4] 退出 immurok.app，抢占 $SOCK"
osascript -e 'tell application "immurok" to quit' 2>/dev/null
for i in {1..25}; do
  pgrep -xq immurok || break
  sleep 0.2
done
if pgrep -xq immurok; then
  echo "immurok.app 未退出，放弃"
  exit 2
fi
APP_STOPPED=1
rm -f "$SOCK"

FAILED=0

run_scenario() {
  local name="$1" reply="$2"
  local before=0 after=0

  [[ -f "$AUDIT_LOG" ]] && before=$(wc -l < "$AUDIT_LOG" | tr -d ' ')

  python3 "$SPOOF_PY" "$SOCK" "$reply" &
  SRV_PID=$!
  sleep 0.5

  sudo -k
  # -S：密码从 stdin 读；</dev/null 立刻 EOF。PAM 拒绝或读不到密码都会
  # 让 sudo 非 0 退出，但只有真的进了 PAM 链才会触发 pam_immurok 的
  # MAC 校验和审计记录——这正是本脚本要验证的。
  if sudo -S true </dev/null >/dev/null 2>&1; then
    echo "FAIL[$name]: sudo 通过了，伪造成功"
    kill "$SRV_PID" 2>/dev/null
    wait "$SRV_PID" 2>/dev/null
    SRV_PID=""
    rm -f "$SOCK"
    FAILED=1
    return
  fi

  wait "$SRV_PID" 2>/dev/null
  SRV_PID=""

  if [[ ! -f "$AUDIT_LOG" ]]; then
    echo "FAIL[$name]: sudo 被拒，但 $AUDIT_LOG 不存在"
    FAILED=1
    rm -f "$SOCK"
    return
  fi

  after=$(wc -l < "$AUDIT_LOG" | tr -d ' ')
  if (( after > before )) && tail -n $((after - before)) "$AUDIT_LOG" | grep -q "MAC_MISMATCH"; then
    local mode
    mode=$(stat -f '%Lp' "$AUDIT_LOG" 2>/dev/null)
    if [[ "$mode" == "644" ]]; then
      echo "PASS[$name]: sudo 拒绝，审计文件记录 MAC_MISMATCH，权限 0644"
    else
      echo "WARN[$name]: sudo 拒绝并记录 MAC_MISMATCH，但审计文件权限是 0$mode（应为 0644）"
    fi
  else
    echo "FAIL[$name]: sudo 被拒，但 $AUDIT_LOG 没有新增带 MAC_MISMATCH 的行"
    FAILED=1
  fi

  rm -f "$SOCK"
}

echo "[2/4] 伪造裸 OK"
run_scenario "bare-OK" "OK"

echo "[3/4] 伪造错误 MAC"
run_scenario "bad-MAC" "OK:00000000000000000000000000000000"

echo "[4/4] 完成"
exit $FAILED
