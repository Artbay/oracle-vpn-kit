#!/usr/bin/env bash
# Hysteria2 端口跳跃：UDP $HY2_HOP_START:$HY2_HOP_END 经 nat REDIRECT 到 $HY2_PORT。
# 注意：跳跃区间不要包含 TUIC_PORT，否则 TUIC 会被重定向到 Hy2。
. "$(dirname "$0")/lib.sh"
need_root; load_env
require VPS_IFACE HY2_PORT HY2_HOP_START HY2_HOP_END
if [ -n "${TUIC_PORT:-}" ] && [ "$TUIC_PORT" -ge "$HY2_HOP_START" ] && [ "$TUIC_PORT" -le "$HY2_HOP_END" ]; then
  die "TUIC_PORT=$TUIC_PORT 落在跳跃区间内，请调整"
fi
backup /etc/iptables/rules.v4
NAT=(PREROUTING -i "$VPS_IFACE" -p udp -m udp --dport "$HY2_HOP_START:$HY2_HOP_END" -j REDIRECT --to-ports "$HY2_PORT")
if iptables -t nat -C "${NAT[@]}" 2>/dev/null; then
  log "nat 跳跃规则已存在"
else
  iptables -t nat -A "${NAT[@]}"
  log "已添加 nat REDIRECT udp $HY2_HOP_START:$HY2_HOP_END -> $HY2_PORT"
fi
open_port udp "$HY2_HOP_START:$HY2_HOP_END"
persist_iptables
iptables -t nat -S PREROUTING
