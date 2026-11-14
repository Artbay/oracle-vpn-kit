#!/usr/bin/env bash
# 自测：用「随机假凭据 + 文档保留 IP（RFC 5737）+ example.com」生成一份订阅，
# 再用 mihomo -t 和 sing-box check 校验（找不到这两个程序就跳过对应校验）。
# 不读取你的 .env，不连接任何服务器，产物放在临时目录并在结束时删除。
# 用法：bash tools/selftest.sh   可用 MIHOMO=/path/mihomo SING_BOX=/path/sing-box 指定程序
set -euo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
u() { python3 -c 'import uuid; print(uuid.uuid4())'; }
h() { openssl rand -hex "$1"; }
# Reality 公钥格式：32 字节 base64url（无填充）
pub="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
cat > "$T/.env" <<ENV
VPS_IP=192.0.2.10
VPS_IFACE=eth0
NODE_PREFIX=Test
VLESS_UUID=$(u)
REALITY_PUBLIC_KEY=$pub
REALITY_SNI=www.example.com
REALITY_PORT=12345
REALITY_SHORT_ID=$(h 8)
XHTTP_PORT=443
XHTTP_PATH=/$(h 10)
XHTTP_SHORT_ID=$(h 8)
WS_LOCAL_PORT=22345
WS_PATH=/$(h 10)
HY2_PORT=23456         # 行尾注释也要能解析
HY2_PASSWORD=$(h 16)
HY2_OBFS_PASSWORD=$(h 16)
HY2_SNI=www.example.org
HY2_HOP_START=40000
HY2_HOP_END=40999
TUIC_PORT=62345
TUIC_UUID=$(u)
TUIC_PASSWORD=$(h 12)
CDN_DOMAIN=cdn.example.com
CF_PREFERRED_IPS=198.51.100.1,203.0.113.2
SUB_FILE_NAME=clash.yaml
ENV
python3 "$KIT_DIR/tools/gen_subscription.py" --env "$T/.env" --out "$T/out" --no-qr
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$T/out/sing-box.json"
python3 -c 'import base64,sys; assert base64.b64decode(open(sys.argv[1]).read()).count(b"://") == 7' "$T/out/v2ray.txt"
echo "[ok] sing-box.json 是合法 JSON，v2ray.txt 含 7 条链接"
# Xray v26.9.8+ REALITY 需要 X25519MLKEM768：Clash 两个 Reality 类节点都要带开关；
# sing-box 上游客户端不兼容，默认不放 Reality，SINGBOX_REALITY=1 时才放
[ "$(grep -c 'support-x25519mlkem768: true' "$T/out/clash.yaml")" = 2 ]
python3 -c 'import json,sys; assert not any(o.get("tls",{}).get("reality") for o in json.load(open(sys.argv[1]))["outbounds"])' "$T/out/sing-box.json"
{ cat "$T/.env"; echo SINGBOX_REALITY=1; } > "$T/.env3"
python3 "$KIT_DIR/tools/gen_subscription.py" --env "$T/.env3" --out "$T/out3" --no-qr >/dev/null
python3 -c 'import json,sys; assert sum(bool(o.get("tls",{}).get("reality")) for o in json.load(open(sys.argv[1]))["outbounds"]) == 1' "$T/out3/sing-box.json"
echo "[ok] Reality 兼容性开关正确（Clash 带 mlkem；sing-box 默认不含 Reality）"

MIHOMO="${MIHOMO:-$(command -v mihomo || true)}"
if [ -n "$MIHOMO" ]; then
  "$MIHOMO" -t -d "$T" -f "$T/out/clash.yaml"
else
  echo "[skip] 未找到 mihomo，跳过 Clash 配置校验"
fi
SING_BOX="${SING_BOX:-$(command -v sing-box || true)}"
if [ -n "$SING_BOX" ]; then
  "$SING_BOX" check -c "$T/out/sing-box.json" && echo "[ok] sing-box check 通过"
else
  echo "[skip] 未找到 sing-box，跳过 sing-box 配置校验"
fi
# 只部署部分组件：没有 CDN 域名时 --without cdn,tuic 也能生成并通过校验
grep -vE '^(CDN_DOMAIN|CF_PREFERRED_IPS)=' "$T/.env" > "$T/.env2"
python3 "$KIT_DIR/tools/gen_subscription.py" --env "$T/.env2" --out "$T/out2" --no-qr --without cdn,tuic
python3 -c 'import base64,sys; assert base64.b64decode(open(sys.argv[1]).read()).count(b"://") == 3' "$T/out2/v2ray.txt"
[ -n "$MIHOMO" ] && "$MIHOMO" -t -d "$T" -f "$T/out2/clash.yaml" >/dev/null && echo "[ok] 部分组件 Clash 校验通过"
[ -n "$SING_BOX" ] && "$SING_BOX" check -c "$T/out2/sing-box.json" && echo "[ok] 部分组件 sing-box 校验通过"
echo "[ok] 自测完成"
