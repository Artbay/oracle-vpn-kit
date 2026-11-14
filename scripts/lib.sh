#!/usr/bin/env bash
# 公共函数：被其它脚本 source。所有脚本都需在服务器上以 root 手动执行，不会自动连接任何机器。
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$KIT_DIR/.env}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/oracle-vpn-kit}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_0=$'\033[0m'
else
  C_G=""; C_Y=""; C_R=""; C_0=""
fi
log()  { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo）"; }

# load_env：逐行解析 KEY=VALUE（不 source，避免 <占位符> 被 bash 当成重定向而报语法错误）。
# 规则与 tools/gen_subscription.py 一致：忽略空行/注释；值后面「空白 + #」起为注释；去掉成对引号。
load_env() {
  [ -f "$ENV_FILE" ] || die "找不到 $ENV_FILE，先 cp .env.example .env 并填写（或运行 scripts/gen_secrets.sh）"
  local line k v
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
    v="$(printf '%s' "$v" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$v" in \"*\") v="${v:1:${#v}-2}";; \'*\') v="${v:1:${#v}-2}";; esac
    printf -v "$k" '%s' "$v"
    export "${k?}"
  done < "$ENV_FILE"
}

# set_value VAR：变量非空且不是 <占位符> 时返回 0
set_value() { [ -n "${!1:-}" ] && [ "${!1#<}" = "${!1}" ]; }

# require VAR...：变量必须非空且不是 <占位符>
require() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "变量 $v 为空，请在 .env 中填写"
    case "${!v}" in "<"*) die "变量 $v 仍是占位符";; esac
  done
}

# require_port VAR...：必须是 1-65535 的整数
require_port() {
  local v
  require "$@"
  for v in "$@"; do
    [[ "${!v}" =~ ^[0-9]+$ ]] && [ "${!v}" -ge 1 ] && [ "${!v}" -le 65535 ] || die "变量 $v=${!v} 不是合法端口"
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
# 注意：规则写法需与 uninstall.sh / status.sh 中的 fw_rule 保持一致
fw_rule() {  # fw_rule tcp|udp PORT[:END] -> 输出规则参数（每行一个）
  if [ "$1" = tcp ]; then
    printf '%s\n' -p tcp -m state --state NEW -m tcp --dport "$2" -j ACCEPT
  else
    printf '%s\n' -p "$1" -m "$1" --dport "$2" -j ACCEPT
  fi
}
open_port() {  # open_port tcp|udp PORT[:END]
  local proto="$1" port="$2" rule
  mapfile -t rule < <(fw_rule "$proto" "$port")
  if iptables -C INPUT "${rule[@]}" >/dev/null 2>&1; then
    log "iptables 已放行 $proto $port"
  else
    iptables -I INPUT 1 "${rule[@]}"
    log "iptables 放行 $proto $port"
  fi
}

# fw_cover_count PROTO LO [HI]：INPUT 中覆盖该端口/区间、且不带源地址限制的 ACCEPT 规则条数（只读）
fw_cover_count() {
  iptables -S INPUT 2>/dev/null | awk -v p="$1" -v lo="$2" -v hi="${3:-$2}" '
    / -j ACCEPT/ && $0 ~ (" -p " p " ") && $0 !~ / -s / {
      for (i = 1; i < NF; i++) if ($i == "--dport") {
        n = split($(i + 1), r, ":"); a = r[1] + 0; b = (n > 1 ? r[2] : r[1]) + 0
        if (a <= lo + 0 && b >= hi + 0) { c++; break }
      }
    }
    END { print c + 0 }'
}
fw_covered() { [ "$(fw_cover_count "$@")" -gt 0 ]; }

# Hy2 端口跳跃的 nat 规则（setup_port_hopping / status / uninstall 共用）
hop_rule() {
  printf '%s\n' PREROUTING -i "$VPS_IFACE" -p udp -m udp --dport "$HY2_HOP_START:$HY2_HOP_END" -j REDIRECT --to-ports "$HY2_PORT"
}

persist_iptables() {
  if ! command -v netfilter-persistent >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null
  fi
  # 规则与已保存的一致就不重写（去掉注释和计数后比较），保持重复运行无副作用
  if [ -f /etc/iptables/rules.v4 ] && [ -f /etc/iptables/rules.v6 ] \
     && cmp -s <(rules_norm < /etc/iptables/rules.v4) <(iptables-save | rules_norm) \
     && cmp -s <(rules_norm < /etc/iptables/rules.v6) <(ip6tables-save | rules_norm); then
    log "iptables 规则无变化，已持久化"
    return 0
  fi
  netfilter-persistent save >/dev/null && log "iptables 规则已持久化（/etc/iptables/rules.v4）"
}
rules_norm() { grep -v '^#' | sed -E 's/^(:[^ ]+ [^ ]+) \[[0-9]+:[0-9]+\]$/\1/'; }

# ensure_user NAME [HOME]：系统用户；给了 HOME 则保证该目录存在（unit 里 WorkingDirectory=~ 需要）
ensure_user() {
  if ! id "$1" >/dev/null 2>&1; then
    if [ -n "${2:-}" ]; then
      useradd --system --home-dir "$2" --no-create-home --shell /usr/sbin/nologin "$1"
    else
      useradd --system --no-create-home --shell /usr/sbin/nologin "$1"
    fi
  fi
  if [ -n "${2:-}" ]; then
    local h; h="$(getent passwd "$1" | cut -d: -f6)"
    [ -d "$h" ] || install -d -m 750 -o "$1" -g "$(id -gn "$1")" "$h"
  fi
}

# xray_test CONFIG [XRAY_BIN]：去掉 log 段后在临时目录自检，避免以 root 身份创建日志文件（会导致服务用户无权写日志）
xray_test() {
  local t rc=0 out
  t="$(mktemp -d)"
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c.pop("log",None); json.dump(c,open(sys.argv[2],"w"))' \
    "$1" "$t/config.json" || { rm -rf "$t"; return 1; }
  out="$("${2:-xray}" run -test -config "$t/config.json" 2>&1)" || rc=$?
  rm -rf "$t"
  [ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -n 3 >&2
  return "$rc"
}

# ---------------- 官方二进制下载与校验（install_* 与 update.sh 共用，不使用 curl|bash） ----------------

# arch_of xray|hy2|tuic：把 uname -m 映射到各项目的发布文件名
arch_of() {
  local m; m="$(uname -m)"
  case "$1:$m" in
    xray:x86_64) echo 64;;           xray:aarch64) echo arm64-v8a;;
    hy2:x86_64)  echo amd64;;        hy2:aarch64)  echo arm64;;
    tuic:x86_64) echo x86_64-unknown-linux-gnu;; tuic:aarch64) echo aarch64-unknown-linux-gnu;;
    *) die "不支持的架构 $m（仅支持 x86_64 / aarch64）";;
  esac
}

fetch() { curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"; }

# gh_latest_tag OWNER/REPO [TAG_PREFIX]：最新正式版 tag（可按前缀过滤，跳过预发布）
gh_latest_tag() {
  curl -fsSL --retry 3 "https://api.github.com/repos/$1/releases?per_page=50" | python3 -c '
import json, sys
prefix = sys.argv[1]
for r in json.load(sys.stdin):
    if r.get("draft") or r.get("prerelease"):
        continue
    if r["tag_name"].startswith(prefix):
        print(r["tag_name"]); break
' "${2:-}"
}

# verify_sha256 FILE EXPECTED
verify_sha256() {
  local got; got="$(sha256sum "$1" | awk '{print $1}')"
  [ -n "$2" ] || die "没有可用的 sha256，拒绝安装 $1"
  [ "$got" = "$2" ] || die "sha256 不匹配（期望 $2，实际 $got），已中止"
  log "sha256 校验通过"
}

# 各核心的「下载 + 校验」：把可安装的文件放到目录 $1，打印版本号
# Xray：官方 .dgst 文件中的 SHA2-256
xray_download() {  # xray_download DIR [vX.Y.Z]
  local dir="$1" ver="${2:-}" a zip sum
  [ -n "$ver" ] || ver="$(gh_latest_tag XTLS/Xray-core v)"
  [ -n "$ver" ] || die "查询 Xray 最新版本失败"
  a="$(arch_of xray)"; zip="Xray-linux-$a.zip"
  fetch "https://github.com/XTLS/Xray-core/releases/download/$ver/$zip" "$dir/$zip"
  fetch "https://github.com/XTLS/Xray-core/releases/download/$ver/$zip.dgst" "$dir/$zip.dgst"
  sum="$(awk -F'= ' '/^SHA2-256=/{print $2}' "$dir/$zip.dgst" | tr -d '[:space:]')"
  verify_sha256 "$dir/$zip" "$sum" >&2
  command -v unzip >/dev/null || apt-get install -y unzip >/dev/null
  unzip -oq "$dir/$zip" xray geoip.dat geosite.dat -d "$dir/x"
  echo "$ver"
}
# Hysteria2：官方 hashes.txt
hy2_download() {  # hy2_download DIR [app/vX.Y.Z]
  local dir="$1" ver="${2:-}" a f sum
  [ -n "$ver" ] || ver="$(gh_latest_tag apernet/hysteria app/v)"
  [ -n "$ver" ] || die "查询 Hysteria 最新版本失败"
  a="$(arch_of hy2)"; f="hysteria-linux-$a"
  fetch "https://github.com/apernet/hysteria/releases/download/${ver//\//%2F}/$f" "$dir/$f"
  fetch "https://github.com/apernet/hysteria/releases/download/${ver//\//%2F}/hashes.txt" "$dir/hashes.txt"
  sum="$(awk -v f="build/$f" '$2==f{print $1}' "$dir/hashes.txt")"
  verify_sha256 "$dir/$f" "$sum" >&2
  mv "$dir/$f" "$dir/hysteria"
  echo "$ver"
}
# TUIC：官方 .sha256sum；如设置了 TUIC_SHA256 则以它为准（可钉死已核对的值）
tuic_download() {  # tuic_download DIR [X.Y.Z]
  local dir="$1" ver="${2:-}" a f sum tag
  if [ -z "$ver" ]; then
    tag="$(gh_latest_tag EAimTY/tuic tuic-server-)"; ver="${tag#tuic-server-}"
  fi
  [ -n "$ver" ] || die "查询 TUIC 最新版本失败"
  a="$(arch_of tuic)"; f="tuic-server-$ver-$a"
  fetch "https://github.com/EAimTY/tuic/releases/download/tuic-server-$ver/$f" "$dir/$f"
  if [ -n "${TUIC_SHA256:-}" ]; then
    sum="$TUIC_SHA256"
  else
    fetch "https://github.com/EAimTY/tuic/releases/download/tuic-server-$ver/$f.sha256sum" "$dir/$f.sha256sum"
    sum="$(awk '{print $1}' "$dir/$f.sha256sum")"
  fi
  verify_sha256 "$dir/$f" "$sum" >&2
  mv "$dir/$f" "$dir/tuic-server"
  echo "$ver"
}

# 安装 Xray 的文件布局与官方 Xray-install 一致：/usr/local/bin/xray、/usr/local/share/xray、/usr/local/etc/xray、/var/log/xray
xray_place() {  # xray_place DIR(含 x/xray x/geoip.dat x/geosite.dat)
  install -d -m 755 /usr/local/share/xray /usr/local/etc/xray
  [ -d /var/log/xray ] || install -d -m 755 -o nobody -g nogroup /var/log/xray   # 已存在则不改属主（可能是 xray 用户）
  install -m 755 "$1/x/xray" /usr/local/bin/xray
  install -m 644 "$1/x/geoip.dat" "$1/x/geosite.dat" /usr/local/share/xray/
}

# 当前已安装版本（未安装输出空）
cur_version() {
  case "$1" in
    xray) command -v xray >/dev/null && xray version 2>/dev/null | awk 'NR==1{print "v"$2}';;
    hy2)  [ -x /usr/local/bin/hysteria ] && /usr/local/bin/hysteria version 2>/dev/null | awk 'tolower($1)=="version:"{print "app/"$2; exit}';;
    tuic) [ -x /usr/local/bin/tuic-server ] && /usr/local/bin/tuic-server --version 2>/dev/null | awk '{print $NF; exit}';;
    cloudflared) command -v cloudflared >/dev/null && cloudflared --version 2>/dev/null | awk '{print $3; exit}';;
  esac
  return 0
}
