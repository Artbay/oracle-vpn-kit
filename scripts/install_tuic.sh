#!/usr/bin/env bash
# 安装 TUIC v5（tuic-server，EAimTY/tuic 官方 Release），复用 Hysteria2 的自签证书，独立用户 tuic 运行。
# 请先运行 install_hysteria2.sh（需要它生成的证书）。
# 下载后自动按官方 .sha256sum 校验；也可在 .env 设 TUIC_SHA256 钉死你核对过的值（优先使用）。
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
need_root; load_env
require TUIC_UUID TUIC_PASSWORD
require_port TUIC_PORT
TUIC_VERSION="${TUIC_VERSION:-1.0.0}"

if [ ! -x /usr/local/bin/tuic-server ]; then
  log "安装 tuic-server $TUIC_VERSION（官方 Release + sha256 校验）"
  tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
  tuic_download "$tmpd" "$TUIC_VERSION" >/dev/null
  install -m 755 "$tmpd/tuic-server" /usr/local/bin/tuic-server
  log "已安装 /usr/local/bin/tuic-server"
fi
ensure_user tuic
[ -f /etc/hysteria/server.crt ] || die "未找到 /etc/hysteria/server.crt，请先运行 install_hysteria2.sh"
mkdir -p /etc/tuic
# 证书内容没变就不重写（保持幂等）；权限每次都校正
cmp -s /etc/hysteria/server.crt /etc/tuic/server.crt || install -m 644 -o root -g tuic /etc/hysteria/server.crt /etc/tuic/server.crt
cmp -s /etc/hysteria/server.key /etc/tuic/server.key || install -m 640 -o root -g tuic /etc/hysteria/server.key /etc/tuic/server.key
chown root:tuic /etc/tuic/server.crt /etc/tuic/server.key
chmod 644 /etc/tuic/server.crt; chmod 640 /etc/tuic/server.key
render "$KIT_DIR/templates/tuic-config.json.tmpl" /etc/tuic/config.json 640 root:tuic \
  TUIC_PORT TUIC_UUID TUIC_PASSWORD
UNIT=/etc/systemd/system/tuic-server.service
if ! cmp -s "$KIT_DIR/templates/systemd/tuic-server.service" "$UNIT"; then
  backup "$UNIT"
  install -m 644 "$KIT_DIR/templates/systemd/tuic-server.service" "$UNIT"
fi
systemctl daemon-reload
systemctl enable tuic-server >/dev/null 2>&1
systemctl restart tuic-server
open_port udp "$TUIC_PORT"
persist_iptables
systemctl --no-pager --lines=0 status tuic-server || true
