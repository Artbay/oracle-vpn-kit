#!/usr/bin/env bash
# 安装 Xray，并写入三个入站：Reality-Vision(TCP)、XHTTP+Reality(TCP)、WS(仅 127.0.0.1，给 Cloudflare Tunnel)。
# 二进制来自 XTLS/Xray-core 官方 Release，按官方 .dgst 做 sha256 校验；不执行任何远程脚本。
# 已安装则不重复下载；升级请用 scripts/update.sh xray。
# 用法：sudo bash scripts/install_xray.sh [--bin-only]   --bin-only 只装二进制和 unit（供 gen_secrets.sh 生成 Reality 密钥），不写配置
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
need_root; load_env

if ! command -v xray >/dev/null; then
  log "安装 Xray（官方 Release + sha256 校验）"
  tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
  ver="$(xray_download "$tmpd" "${XRAY_VERSION:-}")"
  xray_place "$tmpd"
  log "已安装 Xray $ver"
else
  log "Xray 已安装：$(xray version | head -n1)"
fi
# 只在没有 xray.service 时写入（兼容此前用官方 Xray-install 装过的机器）
if [ ! -f /etc/systemd/system/xray.service ] && [ ! -f /lib/systemd/system/xray.service ]; then
  install -m 644 "$KIT_DIR/templates/systemd/xray.service" /etc/systemd/system/xray.service
  systemctl daemon-reload
  log "已写入 /etc/systemd/system/xray.service"
fi

# 日志目录与文件归服务用户所有（官方 Xray-install 装的机器是 xray 用户，本工具默认 nobody）
XU="$(systemctl show -p User --value xray 2>/dev/null)"; XU="${XU:-nobody}"
id "$XU" >/dev/null 2>&1 || XU=nobody
install -d -m 755 -o "$XU" -g "$(id -gn "$XU")" /var/log/xray
for f in /var/log/xray/access.log /var/log/xray/error.log; do
  [ -e "$f" ] || install -m 600 -o "$XU" -g "$(id -gn "$XU")" /dev/null "$f"
  chown "$XU:$(id -gn "$XU")" "$f"
done

if [ "${1:-}" = --bin-only ]; then log "--bin-only：已就绪，未写入配置"; exit 0; fi

# 先装好二进制，再检查变量（这样首次可先装 xray，再用 gen_secrets.sh 生成 Reality 密钥）
require VLESS_UUID REALITY_PRIVATE_KEY REALITY_SNI REALITY_SHORT_ID XHTTP_PATH XHTTP_SHORT_ID WS_PATH
require_port REALITY_PORT XHTTP_PORT WS_LOCAL_PORT

CFG=/usr/local/etc/xray/config.json
# 临时文件必须以 .json 结尾：xray 按扩展名识别配置格式
NEW="$(mktemp --suffix=.json /usr/local/etc/xray/.config.XXXXXX)"; trap 'rm -f "$NEW"; rm -rf "${tmpd:-}"' EXIT
# shellcheck disable=SC2016  # 单引号是有意的：交给 envsubst 的变量清单
envsubst '${VLESS_UUID} ${REALITY_PRIVATE_KEY} ${REALITY_SNI} ${REALITY_PORT} ${REALITY_SHORT_ID} ${XHTTP_PORT} ${XHTTP_PATH} ${XHTTP_SHORT_ID} ${WS_LOCAL_PORT} ${WS_PATH}' \
  < "$KIT_DIR/templates/xray-config.json.tmpl" > "$NEW"
chmod 640 "$NEW"; chown "root:$(id -gn "$XU")" "$NEW"   # 服务用户所在组可读
xray_test "$NEW" || die "配置自检失败，未替换 $CFG"
if [ -f "$CFG" ] && cmp -s "$NEW" "$CFG"; then
  log "配置无变化"
else
  backup "$CFG"; mv "$NEW" "$CFG"
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  log "Xray 已重启"
fi
systemctl enable xray >/dev/null 2>&1 || true
systemctl is-active --quiet xray || systemctl start xray
open_port tcp "$REALITY_PORT"
open_port tcp "$XHTTP_PORT"
persist_iptables
systemctl --no-pager --lines=0 status xray || true
