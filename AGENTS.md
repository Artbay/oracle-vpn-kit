# AGENTS.md — operating manual for AI agents

> **中文摘要**：本文件写给代替主人操作的 AI。流程是：先向主人要齐信息 → 在服务器上跑
> `bash scripts/deploy.sh --plan`（只读）→ 把计划讲给主人听并取得**明确批准** →
> `sudo bash scripts/deploy.sh --yes --set ...` 一键部署 → `status.sh` 全部无 FAIL 即完成。
> 安装、开端口、改防火墙、卸载/清除都必须先得到主人批准；**任何密码、UUID、密钥、订阅地址都不许贴进聊天**，
> 客户端配置只以文件形式交给主人本人；`.env` 和 `out/` 绝不能提交到 git。

This repository deploys a personal multi-protocol proxy (Hysteria2 with port hopping, TUIC v5,
VLESS+Reality, VLESS+XHTTP+Reality, optional VLESS+WS through a Cloudflare Tunnel) on one
Ubuntu/Debian VPS, plus a secret-path subscription server. Everything is driven by `.env` and
plain bash scripts; `scripts/deploy.sh` orchestrates them.

## 1. Preconditions

| Requirement | How to check |
|---|---|
| A VPS running Ubuntu 20.04+/Debian 11+ with systemd, x86_64 or aarch64 | `deploy.sh --plan` preflight (`系统`, `架构`, `systemd` lines) |
| SSH access as a user with sudo | owner provides it (see §2) |
| Outbound HTTPS to github.com / api.github.com (and pkg.cloudflare.com for `cdn`) | preflight `可访问 ...` lines |
| The repo checked out **on the VPS** (scripts act on the machine they run on) | `git clone` or copy the repo |
| No other service on the chosen ports (XHTTP defaults to TCP 443) | preflight port lines |

Not supported: containers without systemd (use `docker/` instead), remote-managed (token) Cloudflare
tunnels, Windows hosts.

## 2. Ask the owner first (do not guess these)

Collect all of this **before** running anything that mutates:

1. **Server access**: host/IP, SSH user, how you get the key (the owner places it; never ask them to paste a private key into chat), and confirmation that the user has sudo.
2. **Public IP** of the VPS (`VPS_IP`). You may detect it, but confirm with the owner.
3. **Which protocols** to deploy: any of `xray` (Reality + XHTTP + local WS), `hy2`, `hop` (Hy2 port hopping), `tuic`, `cdn`, `sub` (subscription server). Default is all; `cdn` is skipped automatically when its inputs are missing.
4. **Camouflage SNIs**: `REALITY_SNI` (a real TLS 1.3 site, e.g. `www.example.com`) and `HY2_SNI` (any name for the self-signed cert).
5. **CDN path (optional)**: a domain already on Cloudflare (`CDN_DOMAIN`, e.g. `cdn.example.com`) and a tunnel name (`CF_TUNNEL_NAME`). The **owner** must either open the Cloudflare authorization link printed by `cloudflared tunnel login` themselves or place `~/.cloudflared/cert.pem` on the VPS. You never handle their Cloudflare password. Only one new CNAME is created; never edit their other DNS records or zone settings.
6. **Cloud firewall**: who opens the ports in the provider's security list / security group (OCI security list, etc.). The host firewall is handled by the scripts; the cloud one is not.
7. **Delivery**: where the owner wants the client files (a path on their own machine, a USB stick, etc.). Never a chat message.

## 3. Permission gates (hard rules)

| Action | Needs explicit owner approval | Notes |
|---|---|---|
| `deploy.sh --plan`, `status.sh`, `uninstall.sh --dry-run`, `update.sh --check` | No | read-only |
| `deploy.sh --apply/--yes` (installs packages and binaries, writes systemd units, enables BBR/swap) | **Yes** | show the plan first |
| Opening ports / changing iptables (any install step, `setup_port_hopping.sh`) | **Yes** | covered by approving the plan, but say which ports |
| Cloud security-list changes | **Yes**, and usually done by the owner | |
| Cloudflare login / DNS changes | **Yes**, owner performs the login | only the one CNAME the script adds |
| `update.sh <component>` | **Yes** | |
| `uninstall.sh` (without `--dry-run`), `--purge` | **Yes**, separately for `--purge` | purge deletes keys/certs (a backup tarball is made first) |
| Rotating secrets / changing `.env` values | **Yes** | clients must re-import afterwards |

Always:
- **Never print secrets** in chat or logs: UUIDs, passwords, private/public keys, short IDs, paths, `SUB_TOKEN`, subscription URLs, share links, QR contents. Report "set (N chars, hidden)" like `deploy.sh` does.
- Deliver `out/clash.yaml`, `out/sing-box.json`, `out/links.txt`, `out/v2ray.txt`, `out/qr_*.png` **as files** to the owner only (e.g. `scp` to a path they choose).
- **Never commit `.env` or `out/`** (both are gitignored). Run `python3 tools/scan_repo.py .` before any commit to a fork.
- Do not use `curl | bash`; the scripts already download official releases and verify sha256.
- Do not disable SSH access or touch rules for port 22.

## 4. Deploy step by step

All commands run **on the VPS, inside the repo directory**.

```bash
# 0) get the code onto the VPS
git clone <repo-url> oracle-vpn-kit && cd oracle-vpn-kit

# 1) read-only plan (no root needed, changes nothing)
bash scripts/deploy.sh --plan --set VPS_IP=<ip> --set REALITY_SNI=<sni> --set HY2_SNI=<sni>
#    exit 0 = preflight passed; exit 2 = preflight FAIL (fix first). Either way nothing was modified.

# 2) show the owner: component list, masked config, preflight, numbered steps with the "mutates" column.
#    Get explicit approval.

# 3) apply (one command)
sudo bash scripts/deploy.sh --yes --non-interactive \
  --set VPS_IP=<ip> --set REALITY_SNI=<sni> --set HY2_SNI=<sni>
#    add: --skip cdn            (no domain)          --only hy2,hop,sub   (subset)
#         --set CF_TUNNEL_NAME=<name> --set CDN_DOMAIN=<domain>   (CDN; drop --non-interactive
#                                       if the owner will open the Cloudflare login link live)
```

What `deploy.sh --yes` runs, in order (each step reuses an existing script):

| # | Step | Script | Success signal in output |
|---|---|---|---|
| 1 | preflight | (built in) | no `FAIL` lines |
| 2 | secrets | `gen_secrets.sh KEY=VALUE...` | `.env` exists, mode 600; existing values untouched |
| 3 | prepare | `prepare_host.sh` | BBR/swap/packages lines, no error |
| 4 | xray | `install_xray.sh --bin-only` → `gen_secrets.sh` → `install_xray.sh` | `已安装 Xray ...`, `Xray 已重启`, `Active: active (running)` |
| 5 | hy2 | `install_hysteria2.sh` | `sha256 校验通过`, `hysteria-server.service ... active (running)` |
| 6 | hop | `setup_port_hopping.sh` | `nat 跳跃规则已存在` or `已添加 nat REDIRECT ...` |
| 7 | tuic | `install_tuic.sh` | `sha256 校验通过`, `tuic-server.service ... active (running)` |
| 8 | cdn | `install_cloudflared_tunnel.sh` (skipped with a reason if inputs/cert missing) | cloudflared unit active; `status.sh` shows tunnel connections and CDN origin check |
| 9 | clients | `tools/gen_subscription.py --without <unselected>` | `已生成 ...（N 个节点 ...）` |
| 10 | sub | `serve_subscription.sh out` | `订阅已发布 N 个文件` |
| 11 | status | `status.sh --quiet` | `结果：PASS n  WARN m  FAIL 0` |

Final success signal: `[+] 部署完成。日志：/var/log/oracle-vpn-kit/deploy-<stamp>.log`, exit code 0, followed by
the client file **paths**, the subscription URL **format** (with placeholders), and the TCP/UDP ports to open in the
cloud security list. Tell the owner to open exactly those ports.

Verify any time (read-only):

```bash
sudo bash scripts/status.sh          # exit 1 if any FAIL
sudo bash scripts/status.sh --quiet  # only WARN/FAIL + summary
```

`WARN cloudflared 未安装` is expected when `cdn` was skipped.

On failure, `deploy.sh` stops at the failed step and prints the log path and a resume command such as
`sudo bash scripts/deploy.sh --yes --only <remaining components>`. Fix the cause, then run it. Re-running the whole
deploy is also safe: an unchanged re-run rewrites no files.

### Manual path (same result)

`prepare_host.sh` → `install_xray.sh` (first run exits for missing Reality keys) → `gen_secrets.sh` →
`install_xray.sh` → `install_hysteria2.sh` → `setup_port_hopping.sh` → `install_tuic.sh` →
`install_cloudflared_tunnel.sh` → `python3 tools/gen_subscription.py` → `serve_subscription.sh` → `status.sh`.
See README "快速开始" and `docs/方案.md`.

## 5. Client delivery

- Mihomo / Clash Verge Rev / Clash Meta: `out/clash.yaml` (all nodes). Reality/XHTTP entries set
  `support-x25519mlkem768: true`, which Xray-core v26.9.8+ servers require (tested with Mihomo 1.19.29).
- Xray-based apps (v2rayN with Xray core, v2rayNG): `out/links.txt` or `out/v2ray.txt` (base64).
- sing-box (SFI/SFM/SFA): `out/sing-box.json` contains Hy2, TUIC and CDN only. Upstream sing-box (1.14.x)
  strips the X25519MLKEM768 key share, so it cannot connect to Reality on Xray v26.9.8+; XHTTP is not supported
  by sing-box at all. `SINGBOX_REALITY=1` in `.env` re-adds Reality for patched forks.
- Shadowrocket: QR codes `out/qr_*.png` or the `v2ray.txt` subscription.
- Subscription URL: `http://<VPS_IP>:<SUB_PORT>/<SUB_TOKEN>/<file>`. Build it for the owner privately; treat it as a password.

## 6. Rollback and uninstall

```bash
sudo bash scripts/uninstall.sh --dry-run                # read-only preview (run this first, show the owner)
sudo bash scripts/uninstall.sh --yes [component...]     # stop/remove units and only this kit's firewall/NAT rules
sudo bash scripts/uninstall.sh --yes --purge            # also binaries, configs, certs, subscription dir (tarball backup first)
sudo bash scripts/update.sh --check | <component>       # upgrades verify sha256 and roll back automatically if the service fails
```

- Components for uninstall: `xray hy2 hopping tuic cloudflared sub`.
- Backups: `*.bak-<stamp>` next to edited files; binaries, subscriptions and purge tarballs go to `/var/backups/oracle-vpn-kit/`.
- Not removed automatically (tell the owner): Cloudflare tunnel + its CNAME + `~/.cloudflared/cert.pem`,
  and the cloud security-list rules. SSH (22), BBR and swap are left alone.

## 7. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Hy2/TUIC work, Reality/XHTTP/subscription time out | The owner's ISP blocks TCP to the VPS IP while UDP passes | Use Hy2 (first) / TUIC; for TCP use the `cdn` nodes (Cloudflare preferred IPs via CloudflareST) |
| Nothing connects, `status.sh` all PASS | Cloud security list / security group not opened | Open the ports printed at the end of deploy (TCP and UDP separately) in the provider console |
| Hy2 works on `HY2_PORT` but not with hopping | Hop range not opened in the cloud firewall, or the NAT rule is missing | Open UDP `HY2_HOP_START-HY2_HOP_END` in the cloud console; `status.sh` checks the NAT rule and persistence |
| Hopping range overlaps TUIC | `TUIC_PORT` inside the hop range | `setup_port_hopping.sh` refuses; pick a different range in `.env` and rerun |
| Testing hopping from the VPS itself fails | REDIRECT is in PREROUTING, local traffic never hits it | Test from another machine |
| sing-box: `reality verification failed` | sing-box client vs Xray v26.9.8+ REALITY incompatibility | Use Mihomo or an Xray-based client for Reality; sing-box uses Hy2/TUIC/CDN |
| Mihomo Reality fails | Old `clash.yaml` without `support-x25519mlkem768` or old Mihomo | Regenerate with the current `gen_subscription.py`; update Mihomo |
| `cdn` skipped | No `CF_TUNNEL_NAME`/`CDN_DOMAIN`, or non-interactive without `cert.pem` | Owner opens the login link in an interactive run, or places `cert.pem`; then `deploy.sh --yes --only cdn,sub` |
| Port in use in preflight | Another service (often on 443) | Change the port in `.env` or stop that service (with approval) |
| Client still uses old nodes after a change | Cached subscription | Switch the client to DIRECT, update the subscription, switch back |

## 8. Machine-readable summary

```yaml
kit: oracle-vpn-kit
run_on: target VPS, repo root
entrypoint: scripts/deploy.sh
modes:
  plan:  {flag: --plan, default: true, root: false, mutates: false, exit: {0: preflight ok, 2: preflight fail}}
  apply: {flag: --yes, root: true, mutates: true, requires_owner_approval: true, exit: {0: success, nonzero: stopped at failed step}}
options: [--only LIST, --skip LIST, --non-interactive, --set KEY=VALUE]
components: [xray, hy2, hop, tuic, cdn, sub]
owner_inputs:
  required: [VPS_IP, REALITY_SNI, HY2_SNI]
  optional: [CF_TUNNEL_NAME, CDN_DOMAIN, CF_PREFERRED_IPS, NODE_PREFIX, VPS_IFACE]
  owner_actions: [ssh access with sudo, cloud security list, cloudflare login or cert.pem (cdn only)]
secrets_file: {path: .env, mode: "600", commit: never, generated_by: scripts/gen_secrets.sh, overwrite_existing: false}
log: {dir: /var/log/oracle-vpn-kit, file: "deploy-<stamp>.log", contains_secrets: false}
steps:
  - {id: preflight, script: scripts/deploy.sh (built in), inputs: [owner_inputs], outputs: [], idempotent: true, mutates: false}
  - {id: secrets, script: scripts/gen_secrets.sh, inputs: ["--set values"], outputs: [.env], idempotent: true, mutates: ".env only"}
  - {id: prepare, script: scripts/prepare_host.sh, inputs: [], outputs: [bbr sysctl, swap if none, packages, ssh accept rule], idempotent: true, mutates: true}
  - {id: xray, script: "scripts/install_xray.sh --bin-only; scripts/gen_secrets.sh; scripts/install_xray.sh", inputs: [VLESS_UUID, REALITY_*, XHTTP_*, WS_*], outputs: [/usr/local/bin/xray, /usr/local/etc/xray/config.json, xray.service, "tcp REALITY_PORT, XHTTP_PORT open"], idempotent: true, mutates: true}
  - {id: hy2, script: scripts/install_hysteria2.sh, inputs: [HY2_PORT, HY2_PASSWORD, HY2_OBFS_PASSWORD, HY2_SNI], outputs: [/usr/local/bin/hysteria, /etc/hysteria/, hysteria-server.service, "udp HY2_PORT open"], idempotent: true, mutates: true}
  - {id: hop, script: scripts/setup_port_hopping.sh, inputs: [VPS_IFACE, HY2_PORT, HY2_HOP_START, HY2_HOP_END], outputs: [nat PREROUTING REDIRECT rule, "udp hop range open", /etc/iptables/rules.v4], idempotent: true, mutates: true}
  - {id: tuic, script: scripts/install_tuic.sh, inputs: [TUIC_PORT, TUIC_UUID, TUIC_PASSWORD], outputs: [/usr/local/bin/tuic-server, /etc/tuic/, tuic-server.service, "udp TUIC_PORT open"], idempotent: true, mutates: true}
  - {id: cdn, script: scripts/install_cloudflared_tunnel.sh, inputs: [CF_TUNNEL_NAME, CDN_DOMAIN, WS_LOCAL_PORT], outputs: [cloudflared.service, /etc/cloudflared/config.yml, one proxied CNAME], idempotent: true, mutates: true, interactive: "browser login unless cert.pem exists"}
  - {id: clients, script: tools/gen_subscription.py, inputs: [.env], outputs: [out/clash.yaml, out/sing-box.json, out/links.txt, out/v2ray.txt, out/qr_*.png], idempotent: true, mutates: "out/ only"}
  - {id: sub, script: scripts/serve_subscription.sh, inputs: [out/, SUB_PORT, SUB_TOKEN], outputs: ["/var/www/sub/<SUB_TOKEN>/", clash-sub.service, "tcp SUB_PORT open"], idempotent: true, mutates: true}
  - {id: status, script: scripts/status.sh, inputs: [.env], outputs: ["PASS/WARN/FAIL summary"], idempotent: true, mutates: false}
verify: {command: "sudo bash scripts/status.sh", success: "FAIL 0 and exit code 0"}
rollback:
  preview: "sudo bash scripts/uninstall.sh --dry-run"
  uninstall: "sudo bash scripts/uninstall.sh --yes [xray|hy2|hopping|tuic|cloudflared|sub]"
  purge: "sudo bash scripts/uninstall.sh --yes --purge"
  manual_left_for_owner: [cloudflare tunnel and CNAME, cert.pem, cloud security list rules]
never:
  - print secrets, share links, subscription URLs or QR contents in chat
  - commit .env or out/
  - mutate without owner approval
  - touch ssh port 22 rules or unrelated DNS records
```
