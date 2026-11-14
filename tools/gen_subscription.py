#!/usr/bin/env python3
"""从 .env 生成 Clash/Mihomo 订阅、分享链接和二维码。

用法:
    python3 tools/gen_subscription.py [--env .env] [--out out] [--no-qr]

输出（均在 out/，已被 .gitignore 忽略，内含凭据，切勿提交或转发）:
    out/<SUB_FILE_NAME>   Clash Verge Rev / Mihomo 订阅
    out/links.txt         Shadowrocket 等客户端可导入的分享链接
    out/qr_<节点>.png      二维码（需要 `pip install qrcode[pil]` 或系统有 qrencode）
只在本地运行，不连接任何服务器。
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from urllib.parse import quote

REQUIRED = [
    "VPS_IP", "VLESS_UUID", "REALITY_PUBLIC_KEY", "REALITY_SNI", "REALITY_PORT",
    "REALITY_SHORT_ID", "XHTTP_PORT", "XHTTP_PATH", "XHTTP_SHORT_ID", "WS_PATH",
    "HY2_PORT", "HY2_PASSWORD", "HY2_OBFS_PASSWORD", "HY2_SNI", "HY2_HOP_START",
    "HY2_HOP_END", "TUIC_PORT", "TUIC_UUID", "TUIC_PASSWORD", "CDN_DOMAIN",
]


def load_env(path):
    env = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split(" #", 1)[0].strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def q(v):
    """YAML 标量：统一用 JSON 字符串（JSON 是 YAML 子集），避免特殊字符问题。"""
    return json.dumps(str(v), ensure_ascii=False)


def build(env):
    p = env.get("NODE_PREFIX", "MyVPN")
    ip = env["VPS_IP"]
    nodes, links = [], []

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

    dom = env["CDN_DOMAIN"]
    cdn_servers = [(f"{p}-CDN-{i}", x.strip()) for i, x in
                   enumerate([s for s in env.get("CF_PREFERRED_IPS", "").split(",") if s.strip()], 1)]
    cdn_servers.append((p + "-CDN", dom))
    for name, server in cdn_servers:
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
  xhttp-opts:
    path: {q(env['XHTTP_PATH'])}
    mode: auto""")
    links.append((xh,
        f"vless://{env['VLESS_UUID']}@{ip}:{env['XHTTP_PORT']}?encryption=none&security=reality"
        f"&sni={env['REALITY_SNI']}&fp=chrome&pbk={env['REALITY_PUBLIC_KEY']}"
        f"&sid={env['XHTTP_SHORT_ID']}&type=xhttp&path={quote(env['XHTTP_PATH'], safe='')}"
        f"&mode=auto#{quote(xh)}"))

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
    short-id: {q(env['REALITY_SHORT_ID'])}""")
    links.append((rl,
        f"vless://{env['VLESS_UUID']}@{ip}:{env['REALITY_PORT']}?encryption=none"
        f"&flow=xtls-rprx-vision&security=reality&sni={env['REALITY_SNI']}&fp=chrome"
        f"&pbk={env['REALITY_PUBLIC_KEY']}&sid={env['REALITY_SHORT_ID']}&type=tcp#{quote(rl)}"))

    names = [n for n, _ in links]
    group = "\n".join(f"  - {q(n)}" for n in names + ["DIRECT"])
    rules = [
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve", "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
        "DOMAIN-SUFFIX,cn,DIRECT", "DOMAIN-SUFFIX,baidu.com,DIRECT", "DOMAIN-SUFFIX,qq.com,DIRECT",
        "DOMAIN-SUFFIX,taobao.com,DIRECT", "DOMAIN-SUFFIX,alipay.com,DIRECT",
        "DOMAIN-SUFFIX,bilibili.com,DIRECT", "MATCH,节点选择",
    ]
    yaml = (
        "mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: info\nipv6: false\n"
        "proxies:\n" + "\n".join(nodes) + "\n"
        "proxy-groups:\n- name: 节点选择\n  type: select\n  proxies:\n" + group + "\n"
        "rules:\n" + "\n".join(f"- {r}" for r in rules) + "\n"
    )
    return yaml, links


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
    a = ap.parse_args()

    env = load_env(a.env)
    missing = [k for k in REQUIRED if not env.get(k) or env[k].startswith("<")]
    if missing:
        sys.exit("缺少或仍是占位符的变量: " + ", ".join(missing))

    yaml, links = build(env)
    os.makedirs(a.out, mode=0o700, exist_ok=True)
    old = os.umask(0o077)
    try:
        sub = os.path.join(a.out, env.get("SUB_FILE_NAME", "clash.yaml"))
        with open(sub, "w", encoding="utf-8") as f:
            f.write(yaml)
        with open(os.path.join(a.out, "links.txt"), "w", encoding="utf-8") as f:
            f.write("\n".join(l for _, l in links) + "\n")
        qr_ok = 0
        if not a.no_qr:
            for name, link in links:
                qr_ok += make_qr(link, os.path.join(a.out, f"qr_{name}.png"))
    finally:
        os.umask(old)
    print(f"已生成 {sub}、links.txt（{len(links)} 个节点），二维码 {qr_ok} 张。")
    print("提醒：这些文件含登录凭据，只发给自己，勿提交、勿转发。")


if __name__ == "__main__":
    main()
