#!/usr/bin/env bash
# 生成全部随机凭据，追加到 .env（只填空着的变量，已有值不覆盖）。
# 本地或服务器均可运行；需要 openssl，Reality 密钥需要 xray（未安装时提示稍后补）。
# 输出不回显任何秘密值。
set -euo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$KIT_DIR/.env}"
[ -f "$ENV_FILE" ] || { cp "$KIT_DIR/.env.example" "$ENV_FILE"; echo "[+] 已从 .env.example 创建 $ENV_FILE"; }
chmod 600 "$ENV_FILE"

uuid() { if command -v xray >/dev/null; then xray uuid; else cat /proc/sys/kernel/random/uuid; fi; }
hex()  { openssl rand -hex "$1"; }
path() { echo "/$(openssl rand -hex 10)"; }
rport() { echo $(( $1 + $(od -An -N2 -tu2 /dev/urandom) % ($2 - $1 + 1) )); }  # [$1,$2] 内随机
getv() { grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//'; }

setvar() {  # 仅当变量为空或占位符时写入
  local k="$1" v="$2" cur
  cur="$(grep -E "^$k=" "$ENV_FILE" | head -n1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')" || true
  if [ -n "$cur" ] && [ "${cur#<}" = "$cur" ]; then echo "[=] $k 已有值，跳过"; return; fi
  if grep -qE "^$k=" "$ENV_FILE"; then
    local tmp; tmp="$(mktemp)"
    awk -v k="$k" -v v="$v" -F= '$1==k{print k"="v; next}{print}' "$ENV_FILE" > "$tmp" && cat "$tmp" > "$ENV_FILE" && rm -f "$tmp"
  else
    echo "$k=$v" >> "$ENV_FILE"
  fi
  echo "[+] 已生成 $k"
}

setvar VLESS_UUID "$(uuid)"
setvar REALITY_SHORT_ID "$(hex 8)"
setvar XHTTP_SHORT_ID "$(hex 8)"
setvar XHTTP_PATH "$(path)"
setvar WS_PATH "$(path)"
# 随机端口：TCP 各用不重叠的区间；UDP 跳跃区间长度 1000，TUIC 端口在区间之外
setvar REALITY_PORT "$(rport 10000 14999)"
setvar SUB_PORT "$(rport 15000 19999)"
setvar WS_LOCAL_PORT "$(rport 20000 24999)"
setvar HY2_PORT "$(rport 10000 29999)"
setvar HY2_HOP_START "$(( $(rport 30 59) * 1000 ))"
hs="$(getv HY2_HOP_START)"
case "$hs" in ""|"<"*) ;; *) setvar HY2_HOP_END "$(( hs + 999 ))";; esac
setvar TUIC_PORT "$(rport 61000 64999)"
setvar HY2_PASSWORD "$(hex 16)"
setvar HY2_OBFS_PASSWORD "$(hex 16)"
setvar TUIC_UUID "$(uuid)"
setvar TUIC_PASSWORD "$(openssl rand -base64 24 | tr '+/' '-_' | tr -d '=')"
setvar SUB_TOKEN "$(hex 24)"

if command -v xray >/dev/null; then
  kp="$(xray x25519)"
  # 兼容新旧输出格式：Private key / PrivateKey；Public key / Password(新版公钥字段)
  priv="$(echo "$kp" | awk -F': ' 'tolower($1) ~ /private/ {print $2; exit}')"
  pub="$(echo "$kp"  | awk -F': ' 'tolower($1) ~ /public|password/ {print $2; exit}')"
  if [ -n "$priv" ] && [ -n "$pub" ]; then
    setvar REALITY_PRIVATE_KEY "$priv"
    setvar REALITY_PUBLIC_KEY "$pub"
  else
    echo "[!] 无法解析 xray x25519 输出，请手动填写 REALITY_PRIVATE_KEY / REALITY_PUBLIC_KEY"
  fi
else
  echo "[!] 未找到 xray：装好 Xray 后再运行一次本脚本以生成 Reality 密钥对"
fi
echo "[i] 完成。$ENV_FILE 权限 600，切勿提交或外发。"
