#!/usr/bin/env bash
# 主机基础准备：BBR、1G swap（小内存机器）、iptables-persistent、SSH 放行。
. "$(dirname "$0")/lib.sh"
need_root
apt-get update -y >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip openssl gettext-base iptables-persistent >/dev/null

if [ ! -f /etc/sysctl.d/99-bbr.conf ]; then
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-bbr.conf
  sysctl --system >/dev/null
  log "已启用 BBR"
fi
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  log "已创建 1G swap"
fi
open_port tcp 22
persist_iptables
log "完成。别忘了在 OCI 控制台安全列表放行对应端口（见 docs/方案.md）。"
