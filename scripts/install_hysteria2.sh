#!/usr/bin/env bash
# 安装 Hysteria2：自签证书（CN=$HY2_SNI）、salamander 混淆、伪装为 https://$HY2_SNI。
# 端口跳跃请再运行 setup_port_hopping.sh。
. "$(dirname "$0")/lib.sh"
need_root; load_env
require HY2_PORT HY2_PASSWORD HY2_OBFS_PASSWORD HY2_SNI

if ! command -v hysteria >/dev/null; then
  log "安装 Hysteria2（官方脚本 get.hy2.sh）"
  bash <(curl -fsSL https://get.hy2.sh/)
else
  log "Hysteria 已安装：$(hysteria version 2>/dev/null | grep -i version | head -n1)"
fi
ensure_user hysteria
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
backup /etc/systemd/system/hysteria-server.service
install -m 644 "$KIT_DIR/templates/systemd/hysteria-server.service" /etc/systemd/system/hysteria-server.service
systemctl daemon-reload
systemctl enable hysteria-server >/dev/null 2>&1
systemctl restart hysteria-server
open_port udp "$HY2_PORT"
persist_iptables
systemctl --no-pager --lines=0 status hysteria-server || true
