#!/usr/bin/env bash
# 发布订阅：把 tools/gen_subscription.py 生成的文件放到 /var/www/sub/$SUB_TOKEN/，
# 用 python http.server（nobody 用户）在 TCP $SUB_PORT 提供。根目录与秘密目录都放空 index.html，避免目录列表泄露。
# 发布的文件（存在才发布）：$SUB_FILE_NAME（Clash/Mihomo）、sing-box.json（sing-box）、v2ray.txt（Base64 分享链接，Shadowrocket/v2rayN）。
# 明文 HTTP：订阅 URL 本身就是秘密，只发给自己。
# 旧版本备份放在 $BACKUP_DIR/sub/（不在网站目录内，不会被访问到）。
# 换了 SUB_TOKEN 后再运行本脚本：旧 token 目录会被移到备份目录，旧订阅 URL 立即失效。
# 用法：sudo bash scripts/serve_subscription.sh [输出目录，默认 out/]
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
need_root; load_env
require SUB_TOKEN SUB_FILE_NAME
require_port SUB_PORT
[[ "$SUB_TOKEN" =~ ^[A-Za-z0-9_-]{16,}$ ]] || die "SUB_TOKEN 需为至少 16 位的字母数字（用 gen_secrets.sh 生成）"
SRC_DIR="${1:-$KIT_DIR/out}"
[ -f "$SRC_DIR/$SUB_FILE_NAME" ] || die "找不到 $SRC_DIR/$SUB_FILE_NAME，先运行 python3 tools/gen_subscription.py"

WEB=/var/www/sub
D=$WEB/$SUB_TOKEN
BK="$BACKUP_DIR/sub/$STAMP"
install -d -m 700 "$BACKUP_DIR" "$BACKUP_DIR/sub"
install -d -m 755 "$WEB" "$D"
[ -f "$WEB/index.html" ] || install -m 644 /dev/null "$WEB/index.html"
[ -f "$D/index.html" ] || install -m 644 /dev/null "$D/index.html"

# 撤销旧 token 目录（移到备份目录，不直接删除）
for old in "$WEB"/*/; do
  old="${old%/}"
  [ -d "$old" ] || continue
  [ "$old" = "$D" ] && continue
  install -d -m 700 "$BK"
  mv "$old" "$BK/"
  log "已撤销旧订阅目录（移到 $BK/）"
done
# 清理 v1 版本留在网站目录里的 *.bak-* 备份（移到备份目录）
for f in "$D"/*.bak-*; do
  [ -e "$f" ] || continue
  install -d -m 700 "$BK"; mv "$f" "$BK/"
done

n=0
for name in "$SUB_FILE_NAME" sing-box.json v2ray.txt; do
  [ -f "$SRC_DIR/$name" ] || continue
  if [ -f "$D/$name" ] && cmp -s "$SRC_DIR/$name" "$D/$name"; then
    log "$name 无变化"
  else
    if [ -f "$D/$name" ]; then install -d -m 700 "$BK"; cp -a "$D/$name" "$BK/$name"; fi
    install -m 644 "$SRC_DIR/$name" "$D/$name"
    log "已发布 $name"
  fi
  n=$((n + 1))
done

render "$KIT_DIR/templates/systemd/clash-sub.service" /etc/systemd/system/clash-sub.service 644 root:root SUB_PORT
systemctl daemon-reload
systemctl enable clash-sub >/dev/null 2>&1
systemctl restart clash-sub
open_port tcp "$SUB_PORT"
persist_iptables
log "订阅已发布 $n 个文件。URL 格式：http://<VPS_IP>:$SUB_PORT/<SUB_TOKEN>/<文件名>（真实 URL 不在此打印，请自行拼接并当作密码保管）"
