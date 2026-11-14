#!/usr/bin/env bash
# 公共函数：被其它脚本 source。所有脚本都需在服务器上以 root 手动执行，不会自动连接任何机器。
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$KIT_DIR/.env}"
STAMP="$(date +%Y%m%d-%H%M%S)"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo）"; }

load_env() {
  [ -f "$ENV_FILE" ] || die "找不到 $ENV_FILE，先 cp .env.example .env 并填写（或运行 scripts/gen_secrets.sh）"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
}

# require VAR...：变量必须非空且不是 <占位符>
require() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "变量 $v 为空，请在 .env 中填写"
    case "${!v}" in "<"*) die "变量 $v 仍是占位符";; esac
  done
}

# backup FILE：存在则复制为 FILE.bak-时间戳
backup() { [ -e "$1" ] && cp -a "$1" "$1.bak-$STAMP" && log "已备份 $1 -> $1.bak-$STAMP" || true; }

# render TEMPLATE DEST MODE OWNER VAR...：仅替换列出的变量，避免误替换 $ 字符
render() {
  local tmpl="$1" dest="$2" mode="$3" owner="$4"; shift 4
  command -v envsubst >/dev/null || apt-get install -y gettext-base >/dev/null
  local list="" v
  for v in "$@"; do list="$list \${$v}"; done
  local tmp; tmp="$(mktemp)"
  envsubst "$list" < "$tmpl" > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    log "$dest 无变化"; rm -f "$tmp"; return 0
  fi
  backup "$dest"
  install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$dest"
  rm -f "$tmp"
  log "已写入 $dest"
}

# 主机防火墙：在 REJECT 之前插入 ACCEPT（幂等），并持久化
open_port() {  # open_port tcp|udp PORT[:END]
  local proto="$1" port="$2"
  local rule=(-p "$proto" -m "$proto" --dport "$port" -j ACCEPT)
  [ "$proto" = tcp ] && rule=(-p tcp -m state --state NEW -m tcp --dport "$port" -j ACCEPT)
  if iptables -C INPUT "${rule[@]}" 2>/dev/null; then
    log "iptables 已放行 $proto $port"
  else
    iptables -I INPUT 1 "${rule[@]}"
    log "iptables 放行 $proto $port"
  fi
}

persist_iptables() {
  if ! command -v netfilter-persistent >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null
  fi
  netfilter-persistent save >/dev/null && log "iptables 规则已持久化（/etc/iptables/rules.v4）"
}

ensure_user() { id "$1" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$1"; }
