#!/usr/bin/env bash
# 只读健康检查：不修改任何配置、规则或服务；不打印任何密码 / UUID / 订阅 token。
# 检查项：systemd 服务、监听端口、主机防火墙放行、Hy2 端口跳跃规则、证书有效期、Xray 配置自检、
#        订阅可取回（本机 http）、cloudflared 隧道连接数、CDN 回源（可用 --no-net 跳过）、BBR、磁盘、内存。
# 用法：sudo bash scripts/status.sh [--no-net] [--quiet]
# 退出码：有 FAIL 为 1，否则为 0（WARN 不影响退出码）。
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
set +e   # 健康检查要跑完所有项，不因单项失败退出

NET=1; QUIET=0
for a in "$@"; do
  case "$a" in
    --no-net) NET=0;;
    --quiet|-q) QUIET=1;;
    -h|--help) sed -n '2,6p' "$0"; exit 0;;
    *) die "未知参数 $a";;
  esac
done
load_env

NP=0; NW=0; NF=0
pass() { NP=$((NP + 1)); [ "$QUIET" = 1 ] || printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$*"; }
wrn()  { NW=$((NW + 1)); printf '  %sWARN%s %s\n' "$C_Y" "$C_0" "$*"; }
fail() { NF=$((NF + 1)); printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$*"; }
sec()  { [ "$QUIET" = 1 ] || printf '\n== %s\n' "$*"; }
ROOT=0; [ "$(id -u)" -eq 0 ] && ROOT=1
[ "$ROOT" = 1 ] || warn "非 root 运行：防火墙规则、证书和部分端口进程信息无法检查（建议 sudo）"

# 服务是否「已安装」：有 unit 文件
installed() { systemctl cat "$1" >/dev/null 2>&1; }
HAS_XRAY=0; HAS_HY2=0; HAS_TUIC=0; HAS_CFD=0; HAS_SUB=0
installed xray && HAS_XRAY=1
installed hysteria-server && HAS_HY2=1
installed tuic-server && HAS_TUIC=1
installed cloudflared && HAS_CFD=1
installed clash-sub && HAS_SUB=1

sec "systemd 服务"
for u in xray hysteria-server tuic-server cloudflared clash-sub; do
  if ! installed "$u"; then wrn "$u 未安装（不使用该组件可忽略）"; continue; fi
  st="$(systemctl is-active "$u" 2>/dev/null)"; en="$(systemctl is-enabled "$u" 2>/dev/null)"
  if [ "$st" = active ]; then
    if [ "$en" = enabled ]; then pass "$u active / enabled"; else wrn "$u active 但未设开机自启（$en）"; fi
  else
    fail "$u 状态 $st（journalctl -u $u -n 50 查看原因）"
  fi
done

sec "监听端口"
# listening tcp|udp PORT -> 输出监听地址（每行一个）
listening() { ss -Hln"${1:0:1}" "sport = :$2" 2>/dev/null | awk '{print $4}'; }
chk_port() {  # chk_port tcp|udp VAR 期望(public|local)
  local proto="$1" var="$2" want="$3" port addrs
  set_value "$var" || { wrn "$var 未设置，跳过"; return; }
  port="${!var}"
  addrs="$(listening "$proto" "$port")"
  if [ -z "$addrs" ]; then fail "$proto $var 未在监听"; return; fi
  if [ "$want" = local ]; then
    if printf '%s\n' "$addrs" | grep -qvE '^(127\.0\.0\.1|\[::1\]):'; then
      fail "$proto $var 不应对外监听（应只在 127.0.0.1）"
    else pass "$proto $var 仅本机监听"; fi
  else
    pass "$proto $var 正在监听"
  fi
}
[ "$HAS_XRAY" = 1 ] && { chk_port tcp REALITY_PORT public; chk_port tcp XHTTP_PORT public; chk_port tcp WS_LOCAL_PORT local; }
[ "$HAS_HY2" = 1 ]  && chk_port udp HY2_PORT public
[ "$HAS_TUIC" = 1 ] && chk_port udp TUIC_PORT public
[ "$HAS_SUB" = 1 ]  && chk_port tcp SUB_PORT public

if [ "$ROOT" = 1 ] && command -v iptables >/dev/null; then
  sec "主机防火墙（iptables INPUT 放行）"
  chk_fw() {  # chk_fw tcp|udp VAR [VAR_END]
    local spec rule
    set_value "$2" || return
    spec="${!2}"; [ -n "${3:-}" ] && spec="$spec:${!3}"
    mapfile -t rule < <(fw_rule "$1" "$spec")
    if iptables -C INPUT "${rule[@]}" >/dev/null 2>&1; then pass "INPUT 放行 $1 $2${3:+-$3}"
    elif fw_covered "$1" "${!2}" "${3:+${!3}}"; then pass "INPUT 放行 $1 $2${3:+-$3}（由其它 ACCEPT 规则覆盖，非本工具格式）"
    else fail "INPUT 没有放行 $1 $2${3:+-$3}（OCI 镜像默认 REJECT，外部连不上）"; fi
  }
  [ "$HAS_XRAY" = 1 ] && { chk_fw tcp REALITY_PORT; chk_fw tcp XHTTP_PORT; }
  [ "$HAS_HY2" = 1 ]  && { chk_fw udp HY2_PORT; chk_fw udp HY2_HOP_START HY2_HOP_END; }
  [ "$HAS_TUIC" = 1 ] && chk_fw udp TUIC_PORT
  [ "$HAS_SUB" = 1 ]  && chk_fw tcp SUB_PORT

  sec "Hy2 端口跳跃（nat REDIRECT）"
  if [ "$HAS_HY2" = 1 ] && set_value HY2_HOP_START && set_value HY2_HOP_END && set_value VPS_IFACE; then
    mapfile -t NAT < <(hop_rule)
    if iptables -t nat -C "${NAT[@]}" >/dev/null 2>&1; then pass "跳跃规则存在（HY2_HOP_START-HY2_HOP_END -> HY2_PORT）"
    elif command -v nft >/dev/null && nft list ruleset 2>/dev/null | grep -q "dport $HY2_HOP_START-$HY2_HOP_END.*redirect to :$HY2_PORT"; then
      pass "跳跃规则存在（nftables）"
    else fail "跳跃规则缺失：sudo bash scripts/setup_port_hopping.sh"; fi
    if [ -f /etc/iptables/rules.v4 ] && grep -q -- "--dport $HY2_HOP_START:$HY2_HOP_END" /etc/iptables/rules.v4; then
      pass "跳跃规则已持久化（rules.v4）"
    else wrn "rules.v4 中没有跳跃规则，重启后会丢失：netfilter-persistent save"; fi
    if set_value TUIC_PORT && [ "$TUIC_PORT" -ge "$HY2_HOP_START" ] && [ "$TUIC_PORT" -le "$HY2_HOP_END" ]; then
      fail "TUIC_PORT 落在跳跃区间内，会被重定向到 Hy2"
    fi
  else
    wrn "未安装 Hy2 或未配置跳跃区间，跳过"
  fi
fi

sec "证书与配置"
if [ "$ROOT" = 1 ]; then
  for c in /etc/hysteria/server.crt /etc/tuic/server.crt; do
    [ -f "$c" ] || continue
    end="$(openssl x509 -enddate -noout -in "$c" 2>/dev/null | cut -d= -f2)"
    if ! openssl x509 -checkend 0 -noout -in "$c" >/dev/null 2>&1; then fail "$c 已过期（$end）"
    elif ! openssl x509 -checkend $((30 * 86400)) -noout -in "$c" >/dev/null 2>&1; then wrn "$c 30 天内过期（$end）"
    else pass "$c 有效至 $end"; fi
  done
  if [ "$HAS_XRAY" = 1 ] && command -v xray >/dev/null && [ -f /usr/local/etc/xray/config.json ]; then
    if xray_test /usr/local/etc/xray/config.json 2>/dev/null; then pass "Xray 配置自检通过"
    else fail "Xray 配置自检失败：xray run -test -config /usr/local/etc/xray/config.json"; fi
  fi
fi
for c in xray hy2 tuic cloudflared; do
  v="$(cur_version "$c")"; [ -n "$v" ] && pass "$c 版本 $v"
done

sec "订阅"
if [ "$HAS_SUB" = 1 ] && set_value SUB_PORT && set_value SUB_TOKEN; then
  masked="/${SUB_TOKEN:0:4}****/"
  for name in "${SUB_FILE_NAME:-clash.yaml}" sing-box.json v2ray.txt; do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$SUB_PORT/$SUB_TOKEN/$name")"
    case "$code" in
      200) pass "订阅 ${masked}$name 可取回（HTTP 200）";;
      404) if [ "$name" = "${SUB_FILE_NAME:-clash.yaml}" ]; then fail "订阅 ${masked}$name 404"; else wrn "${masked}$name 未发布（可选）"; fi;;
      *)   fail "订阅 ${masked}$name 取回失败（HTTP $code）";;
    esac
  done
  size="$(curl -s -m 5 "http://127.0.0.1:$SUB_PORT/" | wc -c)"
  if [ "$size" -eq 0 ]; then pass "订阅根目录不列出文件"; else fail "订阅根目录返回了内容，可能泄露 token 目录"; fi
else
  wrn "订阅服务未安装，跳过"
fi

sec "Cloudflare 隧道"
if [ "$HAS_CFD" = 1 ]; then
  ready=""
  for p in 20241 20242 20243 20244 20245; do
    r="$(curl -s -m 2 "http://127.0.0.1:$p/ready" 2>/dev/null)"
    case "$r" in *readyConnections*) ready="$(printf '%s' "$r" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("readyConnections",0))' 2>/dev/null)"; break;; esac
  done
  if [ -z "$ready" ]; then
    n="$(journalctl -u cloudflared --since '-1h' --no-pager 2>/dev/null | grep -c 'Registered tunnel connection')"
    if [ "$n" -gt 0 ]; then pass "最近 1 小时注册过 $n 次隧道连接（未找到 metrics 端口）"
    else wrn "无法读取隧道连接数（metrics 端口未开、或非 root 读不到日志）"; fi
  elif [ "$ready" -ge 2 ]; then pass "隧道已建立 $ready 条连接"
  elif [ "$ready" -ge 1 ]; then wrn "隧道只建立了 $ready 条连接"
  else fail "隧道 0 条连接"; fi
  if [ "$NET" = 1 ] && set_value CDN_DOMAIN && set_value WS_PATH; then
    code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://$CDN_DOMAIN$WS_PATH")"
    case "$code" in
      101|400) pass "CDN 回源正常（HTTP $code）";;
      000) wrn "CDN 域名访问超时（服务器本身到 Cloudflare 的网络问题，或 DNS 未生效）";;
      *) fail "CDN 回源异常（HTTP $code）：检查 ingress 主机名 / WS 路径 / Cloudflare WebSockets 开关";;
    esac
  fi
else
  wrn "cloudflared 未安装，跳过"
fi

sec "系统"
cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
if [ "$cc" = bbr ]; then pass "TCP 拥塞控制 bbr"; else wrn "TCP 拥塞控制为 ${cc:-未知}（prepare_host.sh 会启用 BBR）"; fi
du="$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')"
if [ "$du" -ge 90 ]; then fail "根分区已用 ${du}%"; elif [ "$du" -ge 80 ]; then wrn "根分区已用 ${du}%"; else pass "根分区已用 ${du}%"; fi
ma="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
sw="$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)"
if [ "$ma" -lt 64 ]; then fail "可用内存 ${ma}MiB"; elif [ "$ma" -lt 150 ]; then wrn "可用内存 ${ma}MiB"; else pass "可用内存 ${ma}MiB"; fi
if [ "$sw" -gt 0 ]; then pass "swap ${sw}MiB"; else wrn "没有 swap（1GB 内存机器建议 prepare_host.sh 创建）"; fi

printf '\n结果：%sPASS %d%s  %sWARN %d%s  %sFAIL %d%s\n' "$C_G" "$NP" "$C_0" "$C_Y" "$NW" "$C_0" "$C_R" "$NF" "$C_0"
[ "$NF" -eq 0 ]
