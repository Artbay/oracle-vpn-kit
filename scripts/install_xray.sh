#!/usr/bin/env bash
# 安装/更新 Xray，并写入三个入站：Reality-Vision(TCP)、XHTTP+Reality(TCP)、WS(仅 127.0.0.1，给 Cloudflare Tunnel)。
. "$(dirname "$0")/lib.sh"
need_root; load_env

if ! command -v xray >/dev/null; then
  log "安装 Xray（官方脚本 XTLS/Xray-install）"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
  log "Xray 已安装：$(xray version | head -n1)"
fi

# 先装好二进制，再检查变量（这样首次可先装 xray，再用 gen_secrets.sh 生成 Reality 密钥）
require VLESS_UUID REALITY_PRIVATE_KEY REALITY_SNI REALITY_PORT REALITY_SHORT_ID \
        XHTTP_PORT XHTTP_PATH XHTTP_SHORT_ID WS_LOCAL_PORT WS_PATH

CFG=/usr/local/etc/xray/config.json
render "$KIT_DIR/templates/xray-config.json.tmpl" "$CFG.new" 640 root:root \
  VLESS_UUID REALITY_PRIVATE_KEY REALITY_SNI REALITY_PORT REALITY_SHORT_ID \
  XHTTP_PORT XHTTP_PATH XHTTP_SHORT_ID WS_LOCAL_PORT WS_PATH
chgrp "$(id -gn xray 2>/dev/null || echo nogroup)" "$CFG.new" || true
xray run -test -config "$CFG.new" >/dev/null || die "配置自检失败，未替换 $CFG（检查 $CFG.new）"
if [ -f "$CFG" ] && cmp -s "$CFG.new" "$CFG"; then
  rm -f "$CFG.new"; log "配置无变化"
else
  backup "$CFG"; mv "$CFG.new" "$CFG"
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  log "Xray 已重启"
fi
open_port tcp "$REALITY_PORT"
open_port tcp "$XHTTP_PORT"
persist_iptables
systemctl --no-pager --lines=0 status xray || true
