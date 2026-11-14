#!/usr/bin/env bash
# 卸载本工具装的组件。默认只停用服务、删除 systemd unit、删除本工具添加的防火墙/端口跳跃规则；
# 加 --purge 才删除二进制、配置、证书、订阅目录（删除前先打包备份到 $BACKUP_DIR，权限 600）。
# 只删除与 .env 端口「完全一致」的、由本工具添加的规则；不碰 SSH(22)、BBR/swap、其它任何防火墙规则。
# Cloudflare 侧的隧道和 DNS 记录不会被删除（属于你的账号），脚本最后会提示手动步骤。
#
# 用法：sudo bash scripts/uninstall.sh [--yes] [--purge] [--dry-run] [组件...]
#   组件：xray hy2 hopping tuic cloudflared sub（默认全部；hy2 会连带 hopping）
#   --dry-run  只打印将要执行的命令，不做任何修改（无需 root）
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

YES=0; PURGE=0; DRY=0; COMPS=()
for a in "$@"; do
  case "$a" in
    --yes|-y) YES=1;;
    --purge) PURGE=1;;
    --dry-run|-n) DRY=1;;
    -h|--help) sed -n '2,10p' "$0"; exit 0;;
    xray|hy2|hopping|tuic|cloudflared|sub) COMPS+=("$a");;
    *) die "未知参数 $a";;
  esac
done
[ "${#COMPS[@]}" -gt 0 ] || COMPS=(xray hy2 hopping tuic cloudflared sub)
want() { local c; for c in "${COMPS[@]}"; do [ "$c" = "$1" ] && return 0; done; [ "$1" = hopping ] && want hy2; }
[ "$DRY" = 1 ] || need_root
load_env

run() {
  if [ "$DRY" = 1 ]; then printf '  [dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}
# 删除一条 iptables 规则的所有完全相同的副本
del_rule() {  # del_rule TABLE CHAIN-RULE...
  local t="$1"; shift
  if [ "$DRY" = 1 ]; then
    # root 下 dry-run 用只读的 -C 判断规则是否真的存在，让预览与实际执行一致
    if [ "$(id -u)" -eq 0 ] && ! iptables -t "$t" -C "$@" >/dev/null 2>&1; then
      printf '  [dry-run] 跳过（规则不存在）: iptables -t %s -D %s\n' "$t" "$*"; return
    fi
    run iptables -t "$t" -D "$@"; return
  fi
  while iptables -t "$t" -C "$@" >/dev/null 2>&1; do iptables -t "$t" -D "$@"; log "已删除 iptables -t $t $*"; done
}
del_port() {  # del_port tcp|udp VAR [VAR_END]
  local spec rule
  set_value "$2" || return 0
  spec="${!2}"; [ -n "${3:-}" ] && spec="$spec:${!3}"
  mapfile -t rule < <(fw_rule "$1" "$spec")
  [ "$spec" = 22 ] && { warn "跳过 22 端口（SSH）"; return 0; }
  del_rule filter INPUT "${rule[@]}"
  # 精确规则删掉后，如果还有其它（非本工具格式的）ACCEPT 规则覆盖这个端口，只提示、不删除
  local left=0
  if [ "$(id -u)" -eq 0 ]; then
    left="$(fw_cover_count "$1" "${!2}" "${3:+${!3}}")"
    # dry-run 时精确规则还没删，要扣掉它
    if [ "$DRY" = 1 ] && iptables -C INPUT "${rule[@]}" >/dev/null 2>&1; then left=$((left - 1)); fi
  fi
  if [ "$left" -gt 0 ]; then
    warn "$1 $2${3:+-$3} 仍被其它 ACCEPT 规则放行（不是本工具的格式，未删除）：请用 iptables -S INPUT 自行确认"
  fi
}
stop_unit() {
  local u="$1"
  if systemctl cat "$u" >/dev/null 2>&1; then
    run systemctl disable --now "$u" || true
  fi
  local f
  for f in "/etc/systemd/system/$u.service" "/etc/systemd/system/$u@.service" \
           "/etc/systemd/system/$u.service.d" "/etc/systemd/system/$u@.service.d"; do
    [ -e "$f" ] || continue
    run install -d -m 700 "$BK/units"
    run cp -a "$f" "$BK/units/"
    run rm -rf "$f"
  done
}

# 定时器类 unit（cloudflared 包自带的 cloudflared-update.timer 等）
stop_timer() {
  local u="$1" f
  if systemctl cat "$u.timer" >/dev/null 2>&1; then
    run systemctl disable --now "$u.timer" || true
  fi
  for f in "/etc/systemd/system/$u.timer" "/etc/systemd/system/$u.service"; do
    [ -e "$f" ] || continue
    run install -d -m 700 "$BK/units"
    run cp -a "$f" "$BK/units/"
    run rm -f "$f"
  done
}

BK="$BACKUP_DIR/uninstall-$STAMP"
printf '将卸载组件：%s\n' "${COMPS[*]}"
[ "$PURGE" = 1 ] && printf '  --purge：删除二进制、配置、证书、订阅目录（先打包备份到 %s.tar.gz）\n' "$BK"
printf '  不会改动：SSH、BBR/swap、其它防火墙规则、Cloudflare 账号里的隧道与 DNS\n'
if [ "$YES" != 1 ] && [ "$DRY" != 1 ]; then
  read -r -p "确认继续？输入 yes：" ans
  [ "$ans" = yes ] || die "已取消"
fi
run install -d -m 700 "$BACKUP_DIR"

# --purge：先把将要删除的东西整体打包
PURGE_PATHS=()
if [ "$PURGE" = 1 ]; then
  want xray && PURGE_PATHS+=(/usr/local/etc/xray /usr/local/share/xray /usr/local/bin/xray /var/log/xray)
  want hy2  && PURGE_PATHS+=(/etc/hysteria /usr/local/bin/hysteria)
  want tuic && PURGE_PATHS+=(/etc/tuic /usr/local/bin/tuic-server)
  want cloudflared && PURGE_PATHS+=(/etc/cloudflared)
  want sub  && PURGE_PATHS+=(/var/www/sub)
  exist=(); for p in "${PURGE_PATHS[@]}" /etc/iptables/rules.v4; do if [ -e "$p" ]; then exist+=("$p"); fi; done
  if [ "${#exist[@]}" -gt 0 ]; then
    run tar -czf "$BK.tar.gz" --absolute-names "${exist[@]}"
    run chmod 600 "$BK.tar.gz"
    [ "$DRY" = 1 ] || log "已备份到 $BK.tar.gz"
  fi
fi

[ -f /etc/iptables/rules.v4 ] && run cp -a /etc/iptables/rules.v4 "/etc/iptables/rules.v4.bak-$STAMP"

if want hopping && set_value VPS_IFACE && set_value HY2_HOP_START && set_value HY2_HOP_END && set_value HY2_PORT; then
  mapfile -t NAT < <(hop_rule)
  del_rule nat "${NAT[@]}"
  del_port udp HY2_HOP_START HY2_HOP_END
fi
if want xray; then stop_unit xray; del_port tcp REALITY_PORT; del_port tcp XHTTP_PORT; fi
if want hy2;  then stop_unit hysteria-server; del_port udp HY2_PORT; fi
if want tuic; then stop_unit tuic-server; del_port udp TUIC_PORT; fi
if want sub;  then stop_unit clash-sub; del_port tcp SUB_PORT; fi
if want cloudflared; then stop_unit cloudflared; stop_timer cloudflared-update; fi
run systemctl daemon-reload
if command -v netfilter-persistent >/dev/null; then run netfilter-persistent save; fi

if [ "$PURGE" = 1 ]; then
  for p in "${PURGE_PATHS[@]}"; do if [ -e "$p" ]; then run rm -rf "$p"; fi; done
  want xray && id xray >/dev/null 2>&1 && run userdel xray   # 官方 Xray-install 建的用户
  want hy2  && id hysteria >/dev/null 2>&1 && run userdel hysteria
  want tuic && id tuic >/dev/null 2>&1 && run userdel tuic
  if want cloudflared && dpkg -s cloudflared >/dev/null 2>&1; then
    run apt-get remove -y cloudflared
    [ -f /etc/apt/sources.list.d/cloudflared.list ] && run rm -f /etc/apt/sources.list.d/cloudflared.list
    [ -f /usr/share/keyrings/cloudflare-main.gpg ] && run rm -f /usr/share/keyrings/cloudflare-main.gpg
  fi
fi

if [ "$DRY" = 1 ]; then log "dry-run 结束：以上命令均未执行"; else log "卸载完成。备份目录：$BACKUP_DIR"; fi
if want cloudflared; then
  cat <<'TIP'
[i] Cloudflare 侧需要你本人手动处理（脚本不会动你的账号）：
    1. Cloudflare 面板 → DNS：删除指向隧道的那条 CNAME（只删这一条）；
    2. cloudflared tunnel delete <隧道名>（或在 Zero Trust 面板删除）；
    3. 不再使用时删除 ~/.cloudflared/cert.pem（账号授权证书）。
TIP
fi
echo "[i] OCI 控制台安全列表里为这些端口加的放行规则也请手动删除。"
