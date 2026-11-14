#!/usr/bin/env bash
# 发布订阅：把 tools/gen_subscription.py 生成的 out/$SUB_FILE_NAME 放到 /var/www/sub/$SUB_TOKEN/，
# 用 python http.server（nobody 用户）在 TCP $SUB_PORT 提供。根目录放空 index.html，避免目录列表泄露秘密路径。
# 明文 HTTP：订阅 URL 本身就是秘密，只发给自己。
. "$(dirname "$0")/lib.sh"
need_root; load_env
require SUB_PORT SUB_TOKEN SUB_FILE_NAME VPS_IP
SRC="${1:-$KIT_DIR/out/$SUB_FILE_NAME}"
[ -f "$SRC" ] || die "找不到 $SRC，先在本地运行 python3 tools/gen_subscription.py 并把文件传到服务器"

D=/var/www/sub/$SUB_TOKEN
install -d -m 755 /var/www/sub "$D"
[ -f /var/www/sub/index.html ] || install -m 644 /dev/null /var/www/sub/index.html
[ -f "$D/index.html" ] || install -m 644 /dev/null "$D/index.html"
backup "$D/$SUB_FILE_NAME"
install -m 644 "$SRC" "$D/$SUB_FILE_NAME"

render "$KIT_DIR/templates/systemd/clash-sub.service" /etc/systemd/system/clash-sub.service 644 root:root SUB_PORT
systemctl daemon-reload
systemctl enable clash-sub >/dev/null 2>&1
systemctl restart clash-sub
open_port tcp "$SUB_PORT"
persist_iptables
log "订阅已发布。URL 格式：http://<VPS_IP>:$SUB_PORT/<SUB_TOKEN>/$SUB_FILE_NAME （真实 URL 不在此打印，请自行拼接并当作密码保管）"
