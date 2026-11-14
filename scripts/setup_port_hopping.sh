#!/usr/bin/env bash
# Hysteria2 端口跳跃：UDP $HY2_HOP_START:$HY2_HOP_END 经 nat REDIRECT 到 $HY2_PORT。
# 注意：跳跃区间不要包含 TUIC_PORT，否则 TUIC 会被重定向到 Hy2。
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
need_root; load_env
require VPS_IFACE
require_port HY2_PORT HY2_HOP_START HY2_HOP_END
[ "$HY2_HOP_START" -lt "$HY2_HOP_END" ] || die "HY2_HOP_START 必须小于 HY2_HOP_END"
ip link show "$VPS_IFACE" >/dev/null 2>&1 || die "网卡 $VPS_IFACE 不存在（用 ip -br link 查看）"
if [ "$HY2_PORT" -ge "$HY2_HOP_START" ] && [ "$HY2_PORT" -le "$HY2_HOP_END" ]; then
  die "HY2_PORT=$HY2_PORT 不应落在跳跃区间内"
fi
if set_value TUIC_PORT; then
  require_port TUIC_PORT
  if [ "$TUIC_PORT" -ge "$HY2_HOP_START" ] && [ "$TUIC_PORT" -le "$HY2_HOP_END" ]; then
    die "TUIC_PORT=$TUIC_PORT 落在跳跃区间内，请调整"
  fi
fi
mapfile -t NAT < <(hop_rule)
if iptables -t nat -C "${NAT[@]}" >/dev/null 2>&1; then
  log "nat 跳跃规则已存在"
else
  backup /etc/iptables/rules.v4
  iptables -t nat -A "${NAT[@]}"
  log "已添加 nat REDIRECT udp $HY2_HOP_START:$HY2_HOP_END -> $HY2_PORT"
fi
open_port udp "$HY2_HOP_START:$HY2_HOP_END"
persist_iptables
iptables -t nat -S PREROUTING
