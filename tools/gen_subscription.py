#!/usr/bin/env python3
"""从 .env 生成 Clash/Mihomo 订阅、sing-box 配置、分享链接和二维码。

用法:
    python3 tools/gen_subscription.py [--env .env] [--out out] [--no-qr] [--without cdn,tuic,...]
    --without 可选：hy2, tuic, cdn, xhttp, reality（没部署的组件不放进订阅）

输出（均在 out/，已被 .gitignore 忽略，内含凭据，切勿提交或转发）:
    out/<SUB_FILE_NAME>   Clash Verge Rev / Mihomo 订阅
    out/sing-box.json     sing-box 客户端配置（SFI / SFA / SFM / sing-box 命令行，1.12 及以上）
    out/links.txt         Shadowrocket 等客户端可导入的分享链接
    out/v2ray.txt         同上的 Base64 订阅格式（Shadowrocket / v2rayN 可当订阅导入）
    out/qr_<节点>.png      二维码（需要 `pip install qrcode[pil]` 或系统有 qrencode）
只在本地运行，不连接任何服务器。
"""
import argparse
import base64
import json
import re
import os
import shutil
import subprocess
import sys
from urllib.parse import quote

NODE_KINDS = ["hy2", "tuic", "cdn", "xhttp", "reality"]
NEEDS = {
    "hy2": ["HY2_PORT", "HY2_PASSWORD", "HY2_OBFS_PASSWORD", "HY2_SNI", "HY2_HOP_START", "HY2_HOP_END"],
    "tuic": ["TUIC_PORT", "TUIC_UUID", "TUIC_PASSWORD", "HY2_SNI"],
    "cdn": ["VLESS_UUID", "WS_PATH", "CDN_DOMAIN"],
    "xhttp": ["VLESS_UUID", "REALITY_PUBLIC_KEY", "REALITY_SNI", "XHTTP_PORT", "XHTTP_PATH", "XHTTP_SHORT_ID"],
    "reality": ["VLESS_UUID", "REALITY_PUBLIC_KEY", "REALITY_SNI", "REALITY_PORT", "REALITY_SHORT_ID"],
}
PORT_KEYS = {"hy2": ["HY2_PORT", "HY2_HOP_START", "HY2_HOP_END"], "tuic": ["TUIC_PORT"],
             "xhttp": ["XHTTP_PORT"], "reality": ["REALITY_PORT"], "cdn": []}

def load_env(path):
    env = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = re.split(r"\s+#", line.rstrip("\r\n"), maxsplit=1)[0].strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def q(v):
    """YAML 标量：统一用 JSON 字符串（JSON 是 YAML 子集），避免特殊字符问题。"""
    return json.dumps(str(v), ensure_ascii=False)


def build_nodes(env, kinds):
    p = env.get("NODE_PREFIX", "MyVPN")
    ip = env["VPS_IP"]
    nodes, links = [], []

    if "hy2" in kinds:
        hy2 = p + "-Hy2"
        nodes.append(f"""- name: {q(hy2)}
  type: hysteria2
  server: {q(ip)}
  port: {int(env['HY2_PORT'])}
  ports: {q(env['HY2_HOP_START'] + '-' + env['HY2_HOP_END'])}
  hop-interval: 30
  password: {q(env['HY2_PASSWORD'])}
  sni: {q(env['HY2_SNI'])}
  skip-cert-verify: true
  alpn: [h3]
  obfs: salamander
  obfs-password: {q(env['HY2_OBFS_PASSWORD'])}""")
        links.append((hy2,
            f"hysteria2://{quote(env['HY2_PASSWORD'], safe='')}@{ip}:{env['HY2_PORT']}"
            f"?sni={env['HY2_SNI']}&insecure=1&obfs=salamander"
            f"&obfs-password={quote(env['HY2_OBFS_PASSWORD'], safe='')}"
            f"&mport={env['HY2_HOP_START']}-{env['HY2_HOP_END']}#{quote(hy2)}"))

    if "tuic" in kinds:
        tuic = p + "-TUIC"
        nodes.append(f"""- name: {q(tuic)}
  type: tuic
  server: {q(ip)}
  port: {int(env['TUIC_PORT'])}
  uuid: {q(env['TUIC_UUID'])}
  password: {q(env['TUIC_PASSWORD'])}
  alpn: [h3]
  congestion-controller: bbr
  sni: {q(env['HY2_SNI'])}
  skip-cert-verify: true
  udp-relay-mode: native
  reduce-rtt: true""")
        links.append((tuic,
            f"tuic://{env['TUIC_UUID']}:{quote(env['TUIC_PASSWORD'], safe='')}@{ip}:{env['TUIC_PORT']}"
            f"?sni={env['HY2_SNI']}&alpn=h3&congestion_control=bbr&udp_relay_mode=native"
            f"&allow_insecure=1#{quote(tuic)}"))

    if "cdn" in kinds:
        dom = env["CDN_DOMAIN"]
        for name, server in cdn_servers(env):
            nodes.append(f"""- name: {q(name)}
  type: vless
  server: {q(server)}
  port: 443
  uuid: {q(env['VLESS_UUID'])}
  network: ws
  tls: true
  udp: true
  servername: {q(dom)}
  client-fingerprint: chrome
  ws-opts:
    path: {q(env['WS_PATH'])}
    headers:
      Host: {q(dom)}""")
            links.append((name,
                f"vless://{env['VLESS_UUID']}@{server}:443?encryption=none&security=tls&sni={dom}"
                f"&fp=chrome&type=ws&host={dom}&path={quote(env['WS_PATH'], safe='')}#{quote(name)}"))

    if "xhttp" in kinds:
        xh = p + "-XHTTP"
        nodes.append(f"""- name: {q(xh)}
  type: vless
  server: {q(ip)}
  port: {int(env['XHTTP_PORT'])}
  uuid: {q(env['VLESS_UUID'])}
  network: xhttp
  tls: true
  udp: true
  servername: {q(env['REALITY_SNI'])}
  client-fingerprint: chrome
  reality-opts:
    public-key: {q(env['REALITY_PUBLIC_KEY'])}
    short-id: {q(env['XHTTP_SHORT_ID'])}
    support-x25519mlkem768: true
  xhttp-opts:
    path: {q(env['XHTTP_PATH'])}
    mode: auto""")
        links.append((xh,
            f"vless://{env['VLESS_UUID']}@{ip}:{env['XHTTP_PORT']}?encryption=none&security=reality"
            f"&sni={env['REALITY_SNI']}&fp=chrome&pbk={env['REALITY_PUBLIC_KEY']}"
            f"&sid={env['XHTTP_SHORT_ID']}&type=xhttp&path={quote(env['XHTTP_PATH'], safe='')}"
            f"&mode=auto#{quote(xh)}"))

    if "reality" in kinds:
        rl = p + "-Reality"
        nodes.append(f"""- name: {q(rl)}
  type: vless
  server: {q(ip)}
  port: {int(env['REALITY_PORT'])}
  uuid: {q(env['VLESS_UUID'])}
  network: tcp
  tls: true
  udp: true
  flow: xtls-rprx-vision
  servername: {q(env['REALITY_SNI'])}
  client-fingerprint: chrome
  reality-opts:
    public-key: {q(env['REALITY_PUBLIC_KEY'])}
    short-id: {q(env['REALITY_SHORT_ID'])}
    support-x25519mlkem768: true""")
        links.append((rl,
            f"vless://{env['VLESS_UUID']}@{ip}:{env['REALITY_PORT']}?encryption=none"
            f"&flow=xtls-rprx-vision&security=reality&sni={env['REALITY_SNI']}&fp=chrome"
            f"&pbk={env['REALITY_PUBLIC_KEY']}&sid={env['REALITY_SHORT_ID']}&type=tcp#{quote(rl)}"))

    return nodes, links


DIRECT_SUFFIXES = ["cn", "baidu.com", "qq.com", "taobao.com", "alipay.com", "bilibili.com"]


def build_clash(env, kinds):
    nodes, links = build_nodes(env, kinds)
    names = [n for n, _ in links]
    group = "\n".join(f"  - {q(n)}" for n in names + ["DIRECT"])
    rules = [
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve", "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
    ] + [f"DOMAIN-SUFFIX,{d},DIRECT" for d in DIRECT_SUFFIXES] + ["MATCH,节点选择"]
    yaml = (
        "mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: info\nipv6: false\n"
        "proxies:\n" + "\n".join(nodes) + "\n"
        "proxy-groups:\n- name: 节点选择\n  type: select\n  proxies:\n" + group + "\n"
        "rules:\n" + "\n".join(f"- {r}" for r in rules) + "\n"
    )
    return yaml, links


def cdn_servers(env):
    p = env.get("NODE_PREFIX", "MyVPN")
    ips = [s.strip() for s in env.get("CF_PREFERRED_IPS", "").split(",") if s.strip()]
    out = [(f"{p}-CDN-{i}", x) for i, x in enumerate(ips, 1)]
    out.append((p + "-CDN", env["CDN_DOMAIN"]))
    return out


def singbox_reality(env):
    return env.get("SINGBOX_REALITY", "").strip().lower() in ("1", "true", "yes")


def build_singbox(env, kinds):
    """sing-box 1.12+ 客户端配置。

    - sing-box 不支持 XHTTP 传输，因此不含 XHTTP 节点。
    - 默认也不含 Reality 节点：Xray-core v26.9.8 起 REALITY 服务端要求 ClientHello 带
      X25519MLKEM768 密钥共享，而上游 sing-box（截至 1.14.x）的 REALITY 客户端会删掉它，
      结果必然 "reality verification failed"（sing-box issue #4520）。
      若你的 sing-box 分支已修复，设置 SINGBOX_REALITY=1 再生成即可包含。
    """
    p = env.get("NODE_PREFIX", "MyVPN")
    ip = env["VPS_IP"]
    utls = {"enabled": True, "fingerprint": "chrome"}
    obs = []
    if "hy2" in kinds:
        obs.append({
            "type": "hysteria2", "tag": p + "-Hy2", "server": ip,
            "server_port": int(env["HY2_PORT"]),
            "server_ports": [f"{int(env['HY2_HOP_START'])}:{int(env['HY2_HOP_END'])}"],
            "hop_interval": "30s",
            "password": env["HY2_PASSWORD"],
            "obfs": {"type": "salamander", "password": env["HY2_OBFS_PASSWORD"]},
            "tls": {"enabled": True, "server_name": env["HY2_SNI"], "insecure": True, "alpn": ["h3"]},
        })
    if "tuic" in kinds:
        obs.append({
            "type": "tuic", "tag": p + "-TUIC", "server": ip, "server_port": int(env["TUIC_PORT"]),
            "uuid": env["TUIC_UUID"], "password": env["TUIC_PASSWORD"],
            "congestion_control": "bbr", "udp_relay_mode": "native", "zero_rtt_handshake": True,
            "tls": {"enabled": True, "server_name": env["HY2_SNI"], "insecure": True, "alpn": ["h3"]},
        })
    if "cdn" in kinds:
        dom = env["CDN_DOMAIN"]
        for name, server in cdn_servers(env):
            obs.append({
                "type": "vless", "tag": name, "server": server, "server_port": 443,
                "uuid": env["VLESS_UUID"],
                "tls": {"enabled": True, "server_name": dom, "utls": utls},
                "transport": {"type": "ws", "path": env["WS_PATH"], "headers": {"Host": dom}},
            })
    if "reality" in kinds and singbox_reality(env):
        obs.append({
            "type": "vless", "tag": p + "-Reality", "server": ip, "server_port": int(env["REALITY_PORT"]),
            "uuid": env["VLESS_UUID"], "flow": "xtls-rprx-vision",
            "tls": {"enabled": True, "server_name": env["REALITY_SNI"], "utls": utls,
                    "reality": {"enabled": True, "public_key": env["REALITY_PUBLIC_KEY"],
                                "short_id": env["REALITY_SHORT_ID"]}},
        })
    if not obs:
        return None
    tags = [o["tag"] for o in obs]
    cfg = {
        "log": {"level": "warn", "timestamp": True},
        "dns": {
            "servers": [
                {"type": "https", "tag": "remote", "server": "1.1.1.1", "detour": "节点选择"},
                {"type": "local", "tag": "local"},
            ],
            "rules": [{"domain_suffix": DIRECT_SUFFIXES, "server": "local"}],
            "final": "remote",
            "strategy": "ipv4_only",
        },
        "inbounds": [
            {"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"],
             "auto_route": True, "strict_route": True},
            {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7890},
        ],
        "outbounds": [
            {"type": "selector", "tag": "节点选择", "outbounds": tags + ["direct"], "default": tags[0]},
            {"type": "urltest", "tag": "自动选择", "outbounds": tags,
             "url": "https://www.gstatic.com/generate_204", "interval": "10m"},
            *obs,
            {"type": "direct", "tag": "direct"},
        ],
        "route": {
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"ip_is_private": True, "outbound": "direct"},
                {"domain_suffix": DIRECT_SUFFIXES, "outbound": "direct"},
            ],
            "final": "节点选择",
            "auto_detect_interface": True,
            "default_domain_resolver": "local",
        },
    }
    cfg["outbounds"][0]["outbounds"].insert(0, "自动选择")
    return json.dumps(cfg, ensure_ascii=False, indent=2) + "\n"


def make_qr(text, path):
    try:
        import qrcode  # type: ignore
        qrcode.make(text).save(path)
        return True
    except ImportError:
        pass
    if shutil.which("qrencode"):
        subprocess.run(["qrencode", "-o", path, text], check=True)
        return True
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", default=".env")
    ap.add_argument("--out", default="out")
    ap.add_argument("--no-qr", action="store_true")
    ap.add_argument("--without", default="", help="不放进订阅的节点类型，逗号分隔：" + ",".join(NODE_KINDS))
    a = ap.parse_args()

    skip = {x.strip() for x in a.without.split(",") if x.strip()}
    unknown = skip - set(NODE_KINDS)
    if unknown:
        sys.exit("--without 只能是: " + ",".join(NODE_KINDS) + "；未知: " + ",".join(sorted(unknown)))
    kinds = [k for k in NODE_KINDS if k not in skip]
    if not kinds:
        sys.exit("没有可生成的节点")
    env = load_env(a.env)
    need = ["VPS_IP"] + [v for k in kinds for v in NEEDS[k]]
    missing = sorted({k for k in need if not env.get(k) or env[k].startswith("<")})
    if missing:
        sys.exit("缺少或仍是占位符的变量: " + ", ".join(missing))
    ports = [v for k in kinds for v in PORT_KEYS[k]]
    bad = [k for k in ports if not env[k].isdigit() or not 1 <= int(env[k]) <= 65535]
    if bad:
        sys.exit("端口不合法: " + ", ".join(bad))
    if "hy2" in kinds and int(env["HY2_HOP_START"]) >= int(env["HY2_HOP_END"]):
        sys.exit("HY2_HOP_START 必须小于 HY2_HOP_END")

    yaml, links = build_clash(env, kinds)
    sb = build_singbox(env, kinds)
    os.makedirs(a.out, mode=0o700, exist_ok=True)
    old = os.umask(0o077)
    try:
        sub = os.path.join(a.out, env.get("SUB_FILE_NAME", "clash.yaml"))
        with open(sub, "w", encoding="utf-8") as f:
            f.write(yaml)
        sb_path = os.path.join(a.out, "sing-box.json")
        if sb:
            with open(sb_path, "w", encoding="utf-8") as f:
                f.write(sb)
        elif os.path.exists(sb_path):
            os.remove(sb_path)  # 只剩 XHTTP/Reality 时 sing-box 无可用节点，删掉旧文件避免误用
        plain = "\n".join(l for _, l in links) + "\n"
        with open(os.path.join(a.out, "links.txt"), "w", encoding="utf-8") as f:
            f.write(plain)
        with open(os.path.join(a.out, "v2ray.txt"), "w", encoding="utf-8") as f:
            f.write(base64.b64encode(plain.encode()).decode() + "\n")
        qr_ok = 0
        if not a.no_qr:
            for name, link in links:
                qr_ok += make_qr(link, os.path.join(a.out, f"qr_{name}.png"))
    finally:
        os.umask(old)
    print(f"已生成 {sub}、{'sing-box.json、' if sb else ''}links.txt、v2ray.txt（{len(links)} 个节点：{','.join(kinds)}），二维码 {qr_ok} 张。")
    if sb and "reality" in kinds and not singbox_reality(env):
        print("注意：sing-box.json 不含 Reality/XHTTP 节点（上游 sing-box 与 Xray v26.9.8+ REALITY 不兼容）；"
              "Reality 请用 Mihomo/Clash Meta 或 Xray 内核客户端（v2rayN/v2rayNG）。")
    print("提醒：这些文件含登录凭据，只发给自己，勿提交、勿转发。")


if __name__ == "__main__":
    main()
