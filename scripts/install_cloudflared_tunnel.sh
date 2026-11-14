#!/usr/bin/env bash
# Cloudflare Tunnel（本地管理的命名隧道）：$CDN_DOMAIN -> http://127.0.0.1:$WS_LOCAL_PORT，其余 404。
# 前提：域名已托管在 Cloudflare；Xray 已有 WS 入站（install_xray.sh）。
# 交互步骤：`cloudflared tunnel login` 会打印授权链接，需你本人在浏览器里打开并选择域名。
# 凭据（cert.pem、<隧道ID>.json）只留在服务器，权限 600，绝不入库或外发。
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
need_root; load_env
require CF_TUNNEL_NAME CDN_DOMAIN
require_port WS_LOCAL_PORT

if ! command -v cloudflared >/dev/null; then
  log "从 Cloudflare 官方 apt 源安装 cloudflared"
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -y >/dev/null && apt-get install -y cloudflared >/dev/null
fi
log "cloudflared $(cloudflared --version | awk '{print $3}')"

CF_HOME="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}"; CF_HOME="${CF_HOME:-/root}"
if [ ! -f "$CF_HOME/.cloudflared/cert.pem" ]; then
  log "需要授权：下面会输出一个链接，请你本人在浏览器打开并选择你的域名"
  cloudflared tunnel login
  if [ -f /root/.cloudflared/cert.pem ] && [ "$CF_HOME" != /root ]; then
    mkdir -p "$CF_HOME/.cloudflared"; mv /root/.cloudflared/cert.pem "$CF_HOME/.cloudflared/"
  fi
  [ -f "$CF_HOME/.cloudflared/cert.pem" ] || die "授权未完成：没有找到 cert.pem"
fi
chmod 600 "$CF_HOME/.cloudflared/cert.pem"
export TUNNEL_ORIGIN_CERT="$CF_HOME/.cloudflared/cert.pem"

tunnel_id() {  # 按名称查已存在（未删除）的隧道 ID
  cloudflared tunnel list --name "$CF_TUNNEL_NAME" -o json 2>/dev/null | python3 -c \
    'import sys,json; d=json.load(sys.stdin) or []; print(d[0]["id"] if d else "")'
}
CF_TUNNEL_ID="$(tunnel_id || true)"
if [ -z "$CF_TUNNEL_ID" ]; then
  cloudflared tunnel create "$CF_TUNNEL_NAME" >/dev/null
  CF_TUNNEL_ID="$(tunnel_id)"
  [ -n "$CF_TUNNEL_ID" ] || die "创建隧道后未查到 ID"
  log "已创建隧道 $CF_TUNNEL_NAME"
fi
export CF_TUNNEL_ID
mkdir -p /etc/cloudflared
if [ ! -f "/etc/cloudflared/$CF_TUNNEL_ID.json" ]; then
  [ -f "$CF_HOME/.cloudflared/$CF_TUNNEL_ID.json" ] || die "找不到隧道凭据 $CF_HOME/.cloudflared/<隧道ID>.json（隧道可能是在别的机器上创建的，请把凭据文件拷到这里）"
  install -m 600 "$CF_HOME/.cloudflared/$CF_TUNNEL_ID.json" "/etc/cloudflared/$CF_TUNNEL_ID.json"
fi
chmod 600 "/etc/cloudflared/$CF_TUNNEL_ID.json"
render "$KIT_DIR/templates/cloudflared-config.yml.tmpl" /etc/cloudflared/config.yml 600 root:root \
  CF_TUNNEL_ID CDN_DOMAIN WS_LOCAL_PORT
cloudflared tunnel ingress validate --config /etc/cloudflared/config.yml

# 只新增/指向这一条 proxied CNAME，不改动 zone 内其它任何记录与设置
cloudflared tunnel route dns "$CF_TUNNEL_NAME" "$CDN_DOMAIN" || warn "DNS 记录可能已存在，请在 Cloudflare 面板确认 $CDN_DOMAIN 为 proxied CNAME 指向隧道"

UNIT=/etc/systemd/system/cloudflared.service
if ! cmp -s "$KIT_DIR/templates/systemd/cloudflared.service" "$UNIT"; then
  backup "$UNIT"
  install -m 644 "$KIT_DIR/templates/systemd/cloudflared.service" "$UNIT"
fi
systemctl daemon-reload
systemctl enable cloudflared >/dev/null 2>&1
systemctl restart cloudflared
log "完成。请在 Cloudflare 面板确认：SSL/TLS 模式 Full，Network → WebSockets 开启。"
log "自测：curl -sI -H 'Connection: Upgrade' -H 'Upgrade: websocket' https://$CDN_DOMAIN\$WS_PATH 应得到 400/101 而不是 404"
