#!/usr/bin/env bash
# 一键部署编排：按顺序调用本仓库已有脚本（不重复它们的逻辑）。默认只打印计划，不做任何修改。
#
# 用法：
#   bash scripts/deploy.sh [--plan]                    打印完整计划、预检结果和（脱敏后的）配置，不修改任何东西，无需 root
#   sudo bash scripts/deploy.sh --apply                确认后执行（会要求输入 yes）
#   sudo bash scripts/deploy.sh --yes                  直接执行，不再确认（= --apply + 已确认）
#   选项：--only xray,hy2,...   只做这些组件      --skip cdn,...   跳过这些组件
#         --non-interactive     不提问；需要交互的步骤（Cloudflare 授权登录）会被跳过；执行时必须同时给 --yes
#         --set KEY=VALUE       提供主人决定的值（可多次）：VPS_IP REALITY_SNI HY2_SNI CF_TUNNEL_NAME CDN_DOMAIN
#                               CF_PREFERRED_IPS NODE_PREFIX VPS_IFACE；只填 .env 里空着/占位符的项，不覆盖已有值
#   组件：xray hy2 hop tuic cdn sub（hop = Hy2 端口跳跃，cdn = Cloudflare 隧道，sub = 发布订阅）
#
# 重复运行是安全的：每个子脚本都是幂等的，已有的 .env 值不会被覆盖。失败时会停在出错的那一步并给出续跑命令。
# 日志：/var/log/oracle-vpn-kit/deploy-<时间>.log（不含秘密；Cloudflare 授权步骤的输出只显示在终端）。
# 退出码：--plan 0=预检通过 2=预检有 FAIL（两者都未做任何修改）；执行 0=成功（status 无 FAIL），非 0=失败并已停下。
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

ALL=(xray hy2 hop tuic cdn sub)
MODE=plan; YES=0; NONINT=0; ONLY=""; SKIP=""; SETS=()
OWNER_KEYS="VPS_IP REALITY_SNI HY2_SNI CF_TUNNEL_NAME CDN_DOMAIN CF_PREFERRED_IPS NODE_PREFIX VPS_IFACE"
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) MODE=plan;;
    --apply) MODE=apply;;
    --yes|-y) MODE=apply; YES=1;;
    --only) shift; ONLY="${1:-}";;
    --only=*) ONLY="${1#*=}";;
    --skip) shift; SKIP="${1:-}";;
    --skip=*) SKIP="${1#*=}";;
    --non-interactive) NONINT=1;;
    --set) shift; SETS+=("${1:-}");;
    --set=*) SETS+=("${1#*=}");;
    -h|--help) sed -n '2,/^# shellcheck/{/^# shellcheck/d;p;}' "$0"; exit 0;;
    *) die "未知参数 $1（--help 查看用法）";;
  esac
  shift
done
[ "$NONINT" = 1 ] || [ -t 0 ] || NONINT=1   # 没有终端时自动视为非交互
if [ "$MODE" = apply ] && [ "$NONINT" = 1 ] && [ "$YES" != 1 ]; then
  die "非交互模式执行需要 --yes（表示主人已批准）"
fi

valid_comp() { local c; for c in "${ALL[@]}"; do [ "$c" = "$1" ] && return 0; done; return 1; }
SEL=()
for c in "${ALL[@]}"; do
  if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$c,"* ]]; then continue; fi
  [[ ",$SKIP," == *",$c,"* ]] && continue
  SEL+=("$c")
done
for c in ${ONLY//,/ } ${SKIP//,/ }; do valid_comp "$c" || die "未知组件 $c（可选：${ALL[*]}）"; done
[ "${#SEL[@]}" -gt 0 ] || die "没有选中任何组件"
sel() { local c; for c in "${SEL[@]}"; do [ "$c" = "$1" ] && return 0; done; return 1; }

# ---------------- 配置（只读） ----------------
ENV_NEW=0
if [ -f "$ENV_FILE" ]; then
  load_env
else
  ENV_NEW=1
  ENV_FILE_REAL="$ENV_FILE"; ENV_FILE="$KIT_DIR/.env.example"; load_env; ENV_FILE="$ENV_FILE_REAL"
fi

# --set 的值：只用于 .env 里还空着/占位符的项（与 gen_secrets.sh 的规则一致）
for kv in "${SETS[@]}"; do
  k="${kv%%=*}"; v="${kv#*=}"
  [[ " $OWNER_KEYS " == *" $k "* ]] || die "--set 只接受：$OWNER_KEYS"
  [[ "$v" =~ ^[A-Za-z0-9.,:_-]+$ ]] || die "--set $k 的值含不允许的字符"
  if ! set_value "$k"; then printf -v "$k" '%s' "$v"; export "${k?}"; fi
done

mask_ip()  { case "$1" in "<"*|"") echo "${1:-（空）}";; *) echo "${1%%.*}.***.***.${1##*.}";; esac; }
mask_dom() { case "$1" in "<"*|"") echo "${1:-（空）}";; *) echo "${1:0:2}***.${1#*.}";; esac; }
show_var() {  # show_var VAR 类型(secret|ip|domain|plain)
  local v="${!1:-}"
  if ! set_value "$1"; then
    case "$1" in
      VPS_IP|REALITY_SNI|HY2_SNI) printf '  %-20s %s\n' "$1" "需要主人提供";;
      CF_TUNNEL_NAME|CDN_DOMAIN) printf '  %-20s %s\n' "$1" "需要主人提供（仅 cdn 组件；不提供则跳过 cdn）";;
      VPS_IFACE) printf '  %-20s %s\n' "$1" "未设置（gen_secrets.sh 会按默认路由自动识别）";;
      REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY) printf '  %-20s %s\n' "$1" "未设置（装好 xray 后由 gen_secrets.sh 生成）";;
      CF_PREFERRED_IPS) printf '  %-20s %s\n' "$1" "未设置（可选）";;
      *) printf '  %-20s %s\n' "$1" "未设置（gen_secrets.sh 会随机生成）";;
    esac
    return
  fi
  case "$2" in
    secret) printf '  %-20s 已设置（%d 位，已隐藏）\n' "$1" "${#v}";;
    ip)     printf '  %-20s %s\n' "$1" "$(mask_ip "$v")";;
    domain) printf '  %-20s %s\n' "$1" "$(mask_dom "$v")";;
    *)      printf '  %-20s %s\n' "$1" "$v";;
  esac
}

# 已安装检测（只读）
unit_installed() { systemctl cat "$1" >/dev/null 2>&1; }
cf_cert() {
  local h
  for h in "${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}" /root; do
    [ -n "$h" ] && [ -r "$h/.cloudflared/cert.pem" ] && return 0
  done
  return 1
}
cdn_inputs_ok() {
  set_value CF_TUNNEL_NAME && set_value CDN_DOMAIN && [ "$CDN_DOMAIN" != cdn.example.com ]
}
# CDN 能否执行：参数齐全，且已有 cert.pem 或可以交互授权
CDN_REASON=""
cdn_runnable() {
  if ! cdn_inputs_ok; then CDN_REASON="未填写 CF_TUNNEL_NAME / CDN_DOMAIN（需要主人提供自己的域名，且已托管在 Cloudflare）"; return 1; fi
  if cf_cert || [ -f /etc/cloudflared/config.yml ]; then return 0; fi
  if [ "$NONINT" = 1 ]; then CDN_REASON="还没有 Cloudflare 授权证书 cert.pem，非交互模式无法完成浏览器授权"; return 1; fi
  return 0
}

# ---------------- 预检（只读） ----------------
PF_FAIL=0
pf_ok()   { printf '  %sOK%s   %s\n' "$C_G" "$C_0" "$*"; }
pf_warn() { printf '  %sWARN%s %s\n' "$C_Y" "$C_0" "$*"; }
pf_fail() { printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$*"; PF_FAIL=1; }

port_check() {  # port_check tcp|udp VAR
  local p="${!2:-}" line
  set_value "$2" || { pf_ok "$1 $2 将随机生成"; return; }
  line="$(ss -Hln"${1:0:1}"p "sport = :$p" 2>/dev/null | head -n1)"
  if [ -z "$line" ]; then pf_ok "$1 $2=$p 空闲"; return; fi
  case "$line" in
    *'"xray"'*|*'"hysteria"'*|*'"tuic-server"'*|*'"python3"'*) pf_ok "$1 $2=$p 已被本工具的服务占用（重复部署属正常）";;
    *users:*) pf_fail "$1 $2=$p 被其它程序占用：$(printf '%s' "$line" | grep -o 'users:(("[^"]*"' | cut -d'"' -f2)";;
    *) if [ "$(id -u)" -eq 0 ]; then pf_fail "$1 $2=$p 已被占用"; else pf_warn "$1 $2=$p 已被占用（非 root 看不到进程，可能是本工具的服务）"; fi;;
  esac
}

preflight() {
  echo "== 预检"
  if [ "$(id -u)" -eq 0 ]; then pf_ok "root 权限"
  elif [ "$MODE" = apply ]; then pf_fail "需要 root：sudo bash scripts/deploy.sh ..."
  else pf_warn "非 root（--plan 可以；执行时需 sudo）"; fi
  local id="" ver=""
  if [ -r /etc/os-release ]; then
    id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"; ver="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')"
  fi
  case "$id" in ubuntu|debian) pf_ok "系统 $id $ver";; *) pf_fail "系统 ${id:-未知}：只支持 Ubuntu / Debian";; esac
  if ( arch_of xray >/dev/null ) 2>/dev/null; then pf_ok "架构 $(uname -m)"; else pf_fail "架构 $(uname -m) 不支持（只支持 x86_64 / aarch64）"; fi
  if [ -d /run/systemd/system ]; then pf_ok "systemd 可用"; else pf_fail "没有运行中的 systemd（容器环境请改用 docker/ 方案）"; fi
  local u
  for u in https://github.com https://api.github.com; do
    if curl -fsS -o /dev/null -m 10 -I "$u" 2>/dev/null; then pf_ok "可访问 $u"; else pf_fail "无法访问 $u（下载官方发布包需要）"; fi
  done
  if sel cdn && cdn_inputs_ok; then
    if curl -fsS -o /dev/null -m 10 -I https://pkg.cloudflare.com/ 2>/dev/null; then pf_ok "可访问 pkg.cloudflare.com"; else pf_warn "无法访问 pkg.cloudflare.com（cdn 步骤会失败）"; fi
  fi
  if sel xray; then port_check tcp REALITY_PORT; port_check tcp XHTTP_PORT; port_check tcp WS_LOCAL_PORT; fi
  if sel hy2;  then port_check udp HY2_PORT; fi
  if sel tuic; then port_check udp TUIC_PORT; fi
  if sel sub;  then port_check tcp SUB_PORT; fi
  # 主人必须提供的值
  local need=()
  set_value VPS_IP || need+=(VPS_IP)
  if sel xray; then set_value REALITY_SNI || need+=(REALITY_SNI); fi
  if sel hy2 || sel tuic; then set_value HY2_SNI || need+=(HY2_SNI); fi
  if [ "${#need[@]}" -gt 0 ]; then
    if [ "$MODE" = apply ]; then pf_fail "缺少主人提供的值：${need[*]}（写进 .env 后重跑）"
    else pf_warn "执行前需要主人提供：${need[*]}"; fi
  fi
  if sel tuic && ! sel hy2 && [ ! -f /etc/hysteria/server.crt ]; then pf_fail "tuic 复用 Hy2 的证书：请同时选择 hy2，或先部署 hy2"; fi
  if sel hop && ! sel hy2 && ! unit_installed hysteria-server; then pf_fail "hop 是 Hy2 的端口跳跃：请同时选择 hy2"; fi
  if sel cdn && ! sel xray && ! unit_installed xray; then pf_fail "cdn 回源到 Xray 的 WS 入站：请同时选择 xray"; fi
  if sel cdn; then
    if cdn_runnable; then pf_ok "cdn 可执行$(cf_cert || [ -f /etc/cloudflared/config.yml ] || echo '（需要主人在浏览器里打开授权链接）')"
    else pf_warn "cdn 将跳过：$CDN_REASON"; fi
  fi
}

# 订阅里放哪些节点：本次选中的或机器上已装好的
sub_without() {
  local w=()
  { sel xray || unit_installed xray; } || w+=(xhttp reality)
  { sel hy2 || unit_installed hysteria-server; } || w+=(hy2)
  { sel tuic || unit_installed tuic-server; } || w+=(tuic)
  { { sel cdn && cdn_runnable; } || [ -f /etc/cloudflared/config.yml ]; } || w+=(cdn)
  local IFS=,; echo "${w[*]}"
}

# ---------------- 计划 ----------------
STEPS=()   # "名称|是否修改系统|命令说明"
plan_steps() {
  STEPS=("preflight|否|只读检查：root、系统、架构、systemd、外网、端口、主人输入")
  STEPS+=("secrets|写 .env|bash scripts/gen_secrets.sh（只填空值，权限 600，不覆盖已有值）")
  STEPS+=("prepare|是|bash scripts/prepare_host.sh（BBR、swap、基础包、放行 SSH）")
  if sel xray; then
    STEPS+=("xray|是|install_xray.sh --bin-only → gen_secrets.sh（补 Reality 密钥）→ install_xray.sh（开放 REALITY_PORT、XHTTP_PORT）")
  fi
  sel hy2  && STEPS+=("hy2|是|bash scripts/install_hysteria2.sh（开放 UDP HY2_PORT）")
  sel hop  && STEPS+=("hop|是|bash scripts/setup_port_hopping.sh（nat 跳跃规则，开放 UDP 跳跃区间）")
  sel tuic && STEPS+=("tuic|是|bash scripts/install_tuic.sh（开放 UDP TUIC_PORT）")
  if sel cdn; then
    if cdn_runnable; then STEPS+=("cdn|是|bash scripts/install_cloudflared_tunnel.sh（新增 1 条 proxied CNAME；无 cert.pem 时需主人浏览器授权）")
    else STEPS+=("cdn|跳过|$CDN_REASON"); fi
  fi
  STEPS+=("clients|写 out/|python3 tools/gen_subscription.py --without '$(sub_without)'（生成客户端文件）")
  sel sub  && STEPS+=("sub|是|bash scripts/serve_subscription.sh（开放 TCP SUB_PORT）")
  STEPS+=("status|否|bash scripts/status.sh（只读体检，FAIL 即部署失败）")
}

print_plan() {
  echo "== 组件：${SEL[*]}"
  echo
  echo "== 配置（脱敏）$([ "$ENV_NEW" = 1 ] && echo "：.env 不存在，执行时会由 gen_secrets.sh 创建，下面按 .env.example 显示")"
  show_var VPS_IP ip; show_var VPS_IFACE plain; show_var NODE_PREFIX plain
  if sel xray; then
    show_var REALITY_SNI plain; show_var REALITY_PORT plain; show_var XHTTP_PORT plain; show_var WS_LOCAL_PORT plain
    show_var VLESS_UUID secret; show_var REALITY_PRIVATE_KEY secret; show_var REALITY_PUBLIC_KEY secret
    show_var REALITY_SHORT_ID secret; show_var XHTTP_PATH secret; show_var XHTTP_SHORT_ID secret; show_var WS_PATH secret
  fi
  if sel hy2 || sel tuic; then show_var HY2_SNI plain; fi
  if sel hy2; then show_var HY2_PORT plain; show_var HY2_PASSWORD secret; show_var HY2_OBFS_PASSWORD secret; fi
  if sel hop; then show_var HY2_HOP_START plain; show_var HY2_HOP_END plain; fi
  if sel tuic; then show_var TUIC_PORT plain; show_var TUIC_UUID secret; show_var TUIC_PASSWORD secret; fi
  if sel cdn; then show_var CF_TUNNEL_NAME plain; show_var CDN_DOMAIN domain; show_var CF_PREFERRED_IPS secret; fi
  if sel sub; then show_var SUB_PORT plain; show_var SUB_TOKEN secret; show_var SUB_FILE_NAME plain; fi
  echo
  preflight
  echo
  echo "== 执行顺序（第二列：是否修改系统）"
  local i=1 s
  for s in "${STEPS[@]}"; do
    IFS='|' read -r n m d <<<"$s"
    printf '  %2d. %-9s [%s] %s\n' "$i" "$n" "$m" "$d"; i=$((i + 1))
  done
}

plan_steps
print_plan
if [ "$MODE" = plan ]; then
  echo
  extra=""; for kv in "${SETS[@]}"; do extra="$extra --set ${kv%%=*}=<值>"; done
  for k in VPS_IP REALITY_SNI HY2_SNI; do set_value "$k" || extra="$extra --set $k=<值>"; done
  echo "这是计划，未做任何修改。主人批准后执行：sudo bash scripts/deploy.sh --yes$([ -n "$ONLY" ] && echo " --only $ONLY")$([ -n "$SKIP" ] && echo " --skip $SKIP")$extra"
  if [ "$PF_FAIL" != 0 ]; then echo "注意：预检有 FAIL，执行前需先解决。"; exit 2; fi
  exit 0
fi

# ---------------- 执行 ----------------
[ "$PF_FAIL" = 0 ] || die "预检未通过，未做任何修改。解决上面的 FAIL 后重跑。"
if [ "$YES" != 1 ]; then
  read -r -p "以上计划将修改本机（安装软件、写配置、改防火墙）。确认执行？输入 yes：" ans
  [ "$ans" = yes ] || die "已取消，未做任何修改"
fi

LOG_DIR=/var/log/oracle-vpn-kit
install -d -m 700 "$LOG_DIR"
LOG="$LOG_DIR/deploy-$STAMP.log"
install -m 600 /dev/null "$LOG"
printf 'deploy %s 组件=%s\n' "$STAMP" "${SEL[*]}" >> "$LOG"
CUR=""
on_fail() {
  local rc=$?
  [ "$rc" -eq 0 ] && return
  [ -n "$CUR" ] || return
  printf '\n%s[x] 步骤「%s」失败（退出码 %d）。%s\n' "$C_R" "$CUR" "$rc" "$C_0" >&2
  printf '    日志：%s\n' "$LOG" >&2
  printf '    修好原因后重跑同一条命令即可（已完成的步骤是幂等的），或只续跑剩下的组件：\n' >&2
  printf '    sudo bash scripts/deploy.sh --yes --only %s\n' "$REST" >&2
  printf '%s 失败 %s rc=%d\n' "$(date +%H:%M:%S)" "$CUR" "$rc" >> "$LOG"
}
trap on_fail EXIT

step() {  # step 名称 [--nolog] 命令...
  CUR="$1"; shift
  local nolog=0
  [ "${1:-}" = --nolog ] && { nolog=1; shift; }
  printf '\n%s==> [%s]%s %s\n' "$C_G" "$CUR" "$C_0" "$*"
  printf '%s 开始 %s：%s\n' "$(date +%H:%M:%S)" "$CUR" "$*" >> "$LOG"
  if [ "$nolog" = 1 ]; then
    echo "（本步骤输出只显示在终端，不写日志）" >> "$LOG"
    "$@"
  else
    "$@" 2>&1 | tee -a "$LOG"
    return "${PIPESTATUS[0]}"
  fi
}
S="$KIT_DIR/scripts"
rest_from() {  # 剩下的组件（用于续跑提示）
  local c out=() hit=0
  for c in "${SEL[@]}"; do [ "$c" = "$1" ] && hit=1; [ "$hit" = 1 ] && out+=("$c"); done
  local IFS=,; echo "${out[*]:-$1}"
}
export DEBIAN_FRONTEND=noninteractive

REST="$(rest_from "${SEL[0]}")"
step secrets bash "$S/gen_secrets.sh" "${SETS[@]}"
load_env
need=(); set_value VPS_IP || need+=(VPS_IP); set_value VPS_IFACE || need+=(VPS_IFACE)
if sel xray; then set_value REALITY_SNI || need+=(REALITY_SNI); fi
if sel hy2 || sel tuic; then set_value HY2_SNI || need+=(HY2_SNI); fi
[ "${#need[@]}" -eq 0 ] || { CUR=secrets; die "请在 $ENV_FILE 填写：${need[*]}，然后重跑"; }
step prepare bash "$S/prepare_host.sh"
if sel xray; then
  REST="$(rest_from xray)"
  step xray bash "$S/install_xray.sh" --bin-only
  step xray bash "$S/gen_secrets.sh"
  step xray bash "$S/install_xray.sh"
fi
if sel hy2;  then REST="$(rest_from hy2)";  step hy2  bash "$S/install_hysteria2.sh"; fi
if sel hop;  then REST="$(rest_from hop)";  step hop  bash "$S/setup_port_hopping.sh"; fi
if sel tuic; then REST="$(rest_from tuic)"; step tuic bash "$S/install_tuic.sh"; fi
if sel cdn; then
  REST="$(rest_from cdn)"
  if cdn_runnable; then
    step cdn --nolog bash "$S/install_cloudflared_tunnel.sh"
  else
    warn "跳过 cdn：$CDN_REASON"
    echo "跳过 cdn：$CDN_REASON" >> "$LOG"
  fi
fi
REST="$(rest_from sub)"
load_env
step clients python3 "$KIT_DIR/tools/gen_subscription.py" --env "$ENV_FILE" --out "$KIT_DIR/out" --without "$(sub_without)"
if sel sub; then step sub bash "$S/serve_subscription.sh" "$KIT_DIR/out"; fi
step status bash "$S/status.sh" --quiet
CUR=""
# 让发起 sudo 的用户能读自己的 .env 和客户端文件
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  chown "$SUDO_USER": "$ENV_FILE"; chown -R "$SUDO_USER": "$KIT_DIR/out"
fi
chmod 600 "$ENV_FILE"

echo
log "部署完成。日志：$LOG"
echo "客户端文件（含凭据，只发给主人自己，以文件形式交付，不要把内容贴进聊天）："
for f in "$KIT_DIR"/out/*; do [ -f "$f" ] && echo "  $f"; done
if sel sub; then
  echo "订阅地址格式：http://<VPS_IP>:$SUB_PORT/<SUB_TOKEN>/<文件名>（真实地址请从 .env 自行拼接，当密码保管）"
fi
if sel xray; then
  echo "客户端兼容：Reality / XHTTP 节点请用 Mihomo 内核（clash.yaml，已开 support-x25519mlkem768）或 Xray 内核客户端（links.txt / v2ray.txt）；"
  echo "  sing-box.json 默认不含 Reality（上游 sing-box 与 Xray v26.9.8+ 的 REALITY 不兼容），sing-box 用户走 Hy2 / TUIC / CDN。"
fi
echo
echo "别忘了：在云控制台的安全列表 / 安全组里放行这些入站端口（主机防火墙已由脚本放行）："
tcp="22"; udp=""
if sel xray; then tcp="$tcp, $REALITY_PORT, $XHTTP_PORT"; fi
if sel sub; then tcp="$tcp, $SUB_PORT"; fi
if sel hy2; then udp="$HY2_PORT"; fi
if sel hop; then udp="${udp:+$udp, }$HY2_HOP_START-$HY2_HOP_END"; fi
if sel tuic; then udp="${udp:+$udp, }$TUIC_PORT"; fi
echo "  TCP：$tcp"
[ -n "$udp" ] && echo "  UDP：$udp"
printf '%s 完成\n' "$(date +%H:%M:%S)" >> "$LOG"
