#!/usr/bin/env bash
# 安装 Hysteria2：自签证书（CN=$HY2_SNI）、salamander 混淆、伪装为 https://$HY2_SNI。
# 二进制来自 apernet/hysteria 官方 Release，按官方 hashes.txt 做 sha256 校验；不执行任何远程脚本。
# 端口跳跃请再运行 setup_port_hopping.sh；升级请用 scripts/update.sh hy2。
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
need_root; load_env
require HY2_PASSWORD HY2_OBFS_PASSWORD HY2_SNI
require_port HY2_PORT

if [ ! -x /usr/local/bin/hysteria ]; then
  log "安装 Hysteria2（官方 Release + sha256 校验）"
  tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
  ver="$(hy2_download "$tmpd" "${HY2_VERSION:-}")"
  install -m 755 "$tmpd/hysteria" /usr/local/bin/hysteria
  log "已安装 Hysteria $ver"
else
  log "Hysteria 已安装：$(cur_version hy2)"
fi
ensure_user hysteria /var/lib/hysteria   # unit 里 WorkingDirectory=~ 需要家目录存在
mkdir -p /etc/hysteria
if [ ! -f /etc/hysteria/server.crt ]; then
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
    -subj "/CN=$HY2_SNI" -days 3650 2>/dev/null
  log "已生成自签证书 CN=$HY2_SNI"
fi
chown hysteria:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt
chmod 600 /etc/hysteria/server.key

render "$KIT_DIR/templates/hysteria2-config.yaml.tmpl" /etc/hysteria/config.yaml 640 root:hysteria \
  HY2_PORT HY2_PASSWORD HY2_OBFS_PASSWORD HY2_SNI
UNIT=/etc/systemd/system/hysteria-server.service
if ! cmp -s "$KIT_DIR/templates/systemd/hysteria-server.service" "$UNIT"; then
  backup "$UNIT"
  install -m 644 "$KIT_DIR/templates/systemd/hysteria-server.service" "$UNIT"
fi
systemctl daemon-reload
systemctl enable hysteria-server >/dev/null 2>&1
systemctl restart hysteria-server
open_port udp "$HY2_PORT"
persist_iptables
systemctl --no-pager --lines=0 status hysteria-server || true
