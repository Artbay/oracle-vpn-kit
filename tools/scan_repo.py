#!/usr/bin/env python3
"""提交前的脱敏扫描：在仓库文件里查找疑似真实的 IP、邮箱、UUID、密钥、私钥、令牌。

用法: python3 tools/scan_repo.py [目录，默认仓库根目录]
发现可疑内容时以退出码 1 结束。.env、out/、docker/conf/ 等已被 .gitignore 忽略的目录不扫描。
允许的「公开/示例」值：RFC 5737 文档 IP、私网网段（用于分流规则）、0.0.0.0、127.0.0.1、
公共 DNS 1.1.1.1、sing-box TUN 地址、example.com 系列邮箱。
"""
import ipaddress
import os
import re
import sys

SKIP_DIRS = {".git", "out", "output", "conf", "__pycache__", "node_modules"}
SKIP_FILES = {".env"}
TEXT_EXT = {".md", ".sh", ".py", ".yaml", ".yml", ".json", ".tmpl", ".service", ".example", ".txt", ""}

ALLOW_NETS = [ipaddress.ip_network(n) for n in (
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",   # RFC 5737 文档地址
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8",  # 分流规则里的私网段
)]
ALLOW_IPS = {"0.0.0.0", "1.1.1.1", "172.19.0.1"}

RULES = [
    ("IPv4", re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")),
    ("邮箱", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")),
    ("UUID", re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")),
    ("私钥", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("令牌", re.compile(r"\b(?:ghp_|gho_|github_pat_|glpat-|xox[abp]-|AKIA)[A-Za-z0-9_-]{10,}")),
    ("长随机串", re.compile(r"(?<![A-Za-z0-9_/-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_/-])")),
    ("十六进制串", re.compile(r"(?<![0-9a-fA-F])[0-9a-fA-F]{32,}(?![0-9a-fA-F])")),
    ("订阅/分享链接", re.compile(r"(?:vless|hysteria2|hy2|tuic|vmess|trojan|ss)://[A-Za-z0-9]")),
]
ALLOW_EMAIL_DOMAINS = ("example.com", "example.org", "example.net")


def allowed(kind, val):
    if kind == "IPv4":
        try:
            ip = ipaddress.ip_address(val)
        except ValueError:
            return True  # 版本号之类，不是 IP
        return val in ALLOW_IPS or any(ip in n for n in ALLOW_NETS)
    if kind == "邮箱":
        return val.lower().endswith(ALLOW_EMAIL_DOMAINS)
    if kind == "长随机串":
        return "_" not in val and "-" not in val and val.isalpha() and val.islower()
    return False


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..")
    me = os.path.abspath(__file__)
    hits = 0
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
        for fn in files:
            p = os.path.join(d, fn)
            if fn in SKIP_FILES or os.path.abspath(p) == me:
                continue
            if os.path.splitext(fn)[1] not in TEXT_EXT and fn not in (".gitignore", ".shellcheckrc", "LICENSE"):
                continue
            try:
                lines = open(p, encoding="utf-8").read().splitlines()
            except (UnicodeDecodeError, OSError):
                continue
            for i, line in enumerate(lines, 1):
                for kind, rx in RULES:
                    for m in rx.finditer(line):
                        if allowed(kind, m.group(0)):
                            continue
                        hits += 1
                        shown = m.group(0)
                        if len(shown) > 12:
                            shown = shown[:6] + "…"
                        print(f"{os.path.relpath(p, root)}:{i}: {kind}: {shown}")
    if hits:
        print(f"发现 {hits} 处可疑内容，请确认后再提交。")
        sys.exit(1)
    print("脱敏扫描通过：未发现疑似真实 IP、邮箱、UUID、密钥或链接。")


if __name__ == "__main__":
    main()
