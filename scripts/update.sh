#!/usr/bin/env bash
# 升级核心：xray / hy2 / tuic / cloudflared（可单独或全部）。
# 流程：查最新正式版 → 下载 → 按官方校验文件做 sha256 校验 → 备份旧二进制 →（Xray 先用新二进制自检现有配置）
#       → 替换并重启 → 服务起不来则自动回滚旧二进制 → 最后跑 status.sh。
# cloudflared 走 Cloudflare 官方 apt 源升级（apt 自带签名校验）。
# 用法：sudo bash scripts/update.sh [--check] [--force] [--version 版本] [xray|hy2|tuic|cloudflared|all]
#   --check    只查看当前版本与最新版本，不做修改
#   --force    版本相同也重新安装
#   --version  指定版本（只能配合单个组件），如 xray 的 v26.1.1、hy2 的 app/v2.6.0、tuic 的 1.0.0
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

CHECK=0; FORCE=0; VER=""; COMPS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1;;
    --force) FORCE=1;;
    --version) shift; VER="${1:-}"; [ -n "$VER" ] || die "--version 需要参数";;
    -h|--help) sed -n '2,10p' "$0"; exit 0;;
    xray|hy2|tuic|cloudflared) COMPS+=("$1");;
    all) COMPS=(xray hy2 tuic cloudflared);;
    *) die "未知参数 $1";;
  esac
  shift
done
[ "${#COMPS[@]}" -gt 0 ] || COMPS=(xray hy2 tuic cloudflared)
[ -z "$VER" ] || [ "${#COMPS[@]}" -eq 1 ] || die "--version 只能配合单个组件使用"
[ "$CHECK" = 1 ] || need_root
[ -f "$ENV_FILE" ] && load_env

unit_of() { case "$1" in xray) echo xray;; hy2) echo hysteria-server;; tuic) echo tuic-server;; cloudflared) echo cloudflared;; esac; }
bin_of()  { case "$1" in xray) echo /usr/local/bin/xray;; hy2) echo /usr/local/bin/hysteria;; tuic) echo /usr/local/bin/tuic-server;; esac; }
latest_of() {
  case "$1" in
    xray) gh_latest_tag XTLS/Xray-core v;;
    hy2)  gh_latest_tag apernet/hysteria app/v;;
    tuic) t="$(gh_latest_tag EAimTY/tuic tuic-server-)"; echo "${t#tuic-server-}";;
    cloudflared) apt-cache policy cloudflared 2>/dev/null | awk '/Candidate:/{print $2}';;
  esac
}

# 服务起不来时回滚
restart_or_rollback() {  # restart_or_rollback COMP BACKUP_FILE
  local c="$1" bak="$2" u; u="$(unit_of "$c")"
  systemctl restart "$u" || true
  sleep 3
  if systemctl is-active --quiet "$u"; then
    log "$u 已用新版本运行"
    return 0
  fi
  warn "$u 启动失败，回滚到旧版本"
  journalctl -u "$u" -n 20 --no-pager >&2 || true
  install -m 755 "$bak" "$(bin_of "$c")"
  if [ "$c" = xray ] && [ -d "$BACKUP_DIR/bin/xray-share.$STAMP" ]; then
    cp -a "$BACKUP_DIR/bin/xray-share.$STAMP/." /usr/local/share/xray/
  fi
  systemctl restart "$u" || true
  sleep 2
  if systemctl is-active --quiet "$u"; then log "已回滚，$u 恢复运行"; else warn "回滚后 $u 仍未运行，请手动检查"; fi
  return 1
}

FAILED=0
for c in "${COMPS[@]}"; do
  cur="$(cur_version "$c")"
  if [ -z "$cur" ]; then warn "$c 未安装，跳过"; continue; fi
  want="${VER:-$(latest_of "$c")}"
  [ -n "$want" ] || { warn "$c 查询最新版本失败，跳过"; FAILED=1; continue; }
  printf '%-12s 当前 %-16s 目标 %s\n' "$c" "$cur" "$want"
  [ "$CHECK" = 1 ] && continue
  if [ "$cur" = "$want" ] && [ "$FORCE" != 1 ]; then log "$c 已是目标版本"; continue; fi

  if [ "$c" = cloudflared ]; then
    if dpkg -s cloudflared >/dev/null 2>&1; then
      apt-get update -y >/dev/null
      apt-get install -y --only-upgrade cloudflared >/dev/null
      systemctl restart cloudflared
      sleep 3
      if systemctl is-active --quiet cloudflared; then
        log "cloudflared 已升级到 $(cur_version cloudflared)"
      else
        warn "cloudflared 升级后未运行：可用 apt-get install cloudflared=<旧版本> 回退"; FAILED=1
      fi
    else
      warn "cloudflared 不是通过 apt 安装的，跳过（请改用官方 apt 源，见 install_cloudflared_tunnel.sh）"
    fi
    continue
  fi

  tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
  case "$c" in
    xray) xray_download "$tmpd" "$want" >/dev/null; new="$tmpd/x/xray";;
    hy2)  hy2_download "$tmpd" "$want" >/dev/null; new="$tmpd/hysteria";;
    tuic) tuic_download "$tmpd" "$want" >/dev/null; new="$tmpd/tuic-server";;
  esac
  chmod 755 "$new"
  if [ "$c" = xray ] && [ -f /usr/local/etc/xray/config.json ]; then
    xray_test /usr/local/etc/xray/config.json "$new" \
      || { warn "新版 Xray 无法通过现有配置自检，未替换"; rm -rf "$tmpd"; FAILED=1; continue; }
  fi
  install -d -m 700 "$BACKUP_DIR/bin"
  bak="$BACKUP_DIR/bin/$(basename "$(bin_of "$c")").$STAMP"
  cp -a "$(bin_of "$c")" "$bak"
  log "旧二进制已备份到 $bak"
  if [ "$c" = xray ]; then
    cp -a /usr/local/share/xray "$BACKUP_DIR/bin/xray-share.$STAMP" 2>/dev/null || true
    xray_place "$tmpd"
  else
    install -m 755 "$new" "$(bin_of "$c")"
  fi
  rm -rf "$tmpd"
  restart_or_rollback "$c" "$bak" || FAILED=1
done

[ "$CHECK" = 1 ] && exit 0
echo
bash "$KIT_DIR/scripts/status.sh" --quiet || FAILED=1
[ "$FAILED" = 0 ] || die "有组件升级失败或健康检查未通过，请查看上面的输出"
log "全部完成"
