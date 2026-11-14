#!/usr/bin/env bash
# 安装 TUIC v5（tuic-server 1.0.0，EAimTY/tuic 官方发布），复用 Hysteria2 的自签证书，独立用户 tuic 运行。
# 请先运行 install_hysteria2.sh（需要它生成的证书）。
# 强烈建议设置 TUIC_SHA256（从官方 Release 页面核对），脚本会校验后再安装。
. "$(dirname "$0")/lib.sh"
need_root; load_env
require TUIC_PORT TUIC_UUID TUIC_PASSWORD
TUIC_VERSION="${TUIC_VERSION:-1.0.0}"
URL="https://github.com/EAimTY/tuic/releases/download/tuic-server-${TUIC_VERSION}/tuic-server-${TUIC_VERSION}-x86_64-unknown-linux-gnu"

if [ ! -x /usr/local/bin/tuic-server ]; then
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "$URL"
  got="$(sha256sum "$tmp" | awk '{print $1}')"
  if [ -n "${TUIC_SHA256:-}" ]; then
    [ "$got" = "$TUIC_SHA256" ] || { rm -f "$tmp"; die "sha256 不匹配，已中止"; }
    log "sha256 校验通过"
  else
    warn "未设置 TUIC_SHA256，下载文件 sha256=$got，请到官方 Release 页面核对"
    read -r -p "确认无误继续安装？[y/N] " ans; [ "$ans" = y ] || { rm -f "$tmp"; die "已取消"; }
  fi
  install -m 755 "$tmp" /usr/local/bin/tuic-server; rm -f "$tmp"
  log "已安装 /usr/local/bin/tuic-server"
fi
ensure_user tuic
[ -f /etc/hysteria/server.crt ] || die "未找到 /etc/hysteria/server.crt，请先运行 install_hysteria2.sh"
mkdir -p /etc/tuic
install -m 644 -o root -g tuic /etc/hysteria/server.crt /etc/tuic/server.crt
install -m 640 -o root -g tuic /etc/hysteria/server.key /etc/tuic/server.key
render "$KIT_DIR/templates/tuic-config.json.tmpl" /etc/tuic/config.json 640 root:tuic \
  TUIC_PORT TUIC_UUID TUIC_PASSWORD
backup /etc/systemd/system/tuic-server.service
install -m 644 "$KIT_DIR/templates/systemd/tuic-server.service" /etc/systemd/system/tuic-server.service
systemctl daemon-reload
systemctl enable tuic-server >/dev/null 2>&1
systemctl restart tuic-server
open_port udp "$TUIC_PORT"
persist_iptables
systemctl --no-pager --lines=0 status tuic-server || true
