#!/usr/bin/env bash
# 【可选 Docker 方案】按 .env 把服务端配置渲染到 docker/conf/（已 gitignore），生成自签证书，
# 并在宿主机 iptables 放行端口（与 systemd 方案同一套函数，幂等）。端口跳跃请另跑 scripts/setup_port_hopping.sh。
# 用法：sudo bash docker/prepare.sh
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/../scripts/lib.sh"
need_root; load_env
require VLESS_UUID REALITY_PRIVATE_KEY REALITY_SNI REALITY_SHORT_ID XHTTP_PATH XHTTP_SHORT_ID WS_PATH \
        HY2_PASSWORD HY2_OBFS_PASSWORD HY2_SNI TUIC_UUID TUIC_PASSWORD
require_port REALITY_PORT XHTTP_PORT WS_LOCAL_PORT HY2_PORT TUIC_PORT

C="$KIT_DIR/docker/conf"
install -d -m 750 "$C" "$C/xray" "$C/hysteria" "$C/tuic"
render "$KIT_DIR/templates/xray-config.json.tmpl" "$C/xray/config.json" 640 root:65534 \
  VLESS_UUID REALITY_PRIVATE_KEY REALITY_SNI REALITY_PORT REALITY_SHORT_ID \
  XHTTP_PORT XHTTP_PATH XHTTP_SHORT_ID WS_LOCAL_PORT WS_PATH
# 容器里不写日志文件：访问日志关闭，错误日志输出到 docker logs
sed -i -e 's|"access": "/var/log/xray/access.log"|"access": "none"|' \
       -e 's|"error": "/var/log/xray/error.log"|"error": ""|' "$C/xray/config.json"
render "$KIT_DIR/templates/hysteria2-config.yaml.tmpl" "$C/hysteria/config.yaml" 640 root:65534 \
  HY2_PORT HY2_PASSWORD HY2_OBFS_PASSWORD HY2_SNI
render "$KIT_DIR/templates/tuic-config.json.tmpl" "$C/tuic/config.json" 640 root:65534 \
  TUIC_PORT TUIC_UUID TUIC_PASSWORD
if [ ! -f "$C/hysteria/server.crt" ]; then
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$C/hysteria/server.key" -out "$C/hysteria/server.crt" -subj "/CN=$HY2_SNI" -days 3650 2>/dev/null
  log "已生成自签证书 CN=$HY2_SNI"
fi
install -m 644 -o root -g 65534 "$C/hysteria/server.crt" "$C/tuic/server.crt"
install -m 640 -o root -g 65534 "$C/hysteria/server.key" "$C/tuic/server.key"
chown root:65534 "$C/hysteria/server.crt" "$C/hysteria/server.key" "$C"/*
chmod 640 "$C/hysteria/server.key"
chmod 750 "$C"/*

open_port tcp "$REALITY_PORT"
open_port tcp "$XHTTP_PORT"
open_port udp "$HY2_PORT"
open_port udp "$TUIC_PORT"
persist_iptables
log "完成。下一步：cd docker && docker compose up -d --build"
