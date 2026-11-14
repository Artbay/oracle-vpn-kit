# 分享链接格式（Shadowrocket / v2rayN 等）

以下全部为占位符，由 `tools/gen_subscription.py` 根据 `.env` 生成真实链接与二维码，输出到 `out/`（已 gitignore）。
生成的链接含登录凭据，**只发给自己，不要转发、不要贴到聊天里**。

```text
# Hysteria2（salamander 混淆 + 端口跳跃）
hysteria2://<HY2_PASSWORD>@<VPS_IP>:<HY2_PORT>?sni=<HY2_SNI>&insecure=1&obfs=salamander&obfs-password=<HY2_OBFS_PASSWORD>&mport=<HY2_HOP_START>-<HY2_HOP_END>#<NODE_PREFIX>-Hy2

# TUIC v5
tuic://<TUIC_UUID>:<TUIC_PASSWORD>@<VPS_IP>:<TUIC_PORT>?sni=<HY2_SNI>&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#<NODE_PREFIX>-TUIC

# VLESS + WS + TLS 经 Cloudflare（server 可换成优选 IP，sni/host 保持域名）
vless://<VLESS_UUID>@<CDN_DOMAIN 或 CF 优选 IP>:443?encryption=none&security=tls&sni=<CDN_DOMAIN>&fp=chrome&type=ws&host=<CDN_DOMAIN>&path=<WS_PATH URL 编码>#<NODE_PREFIX>-CDN

# VLESS + XHTTP + Reality
vless://<VLESS_UUID>@<VPS_IP>:<XHTTP_PORT>?encryption=none&security=reality&sni=<REALITY_SNI>&fp=chrome&pbk=<REALITY_PUBLIC_KEY>&sid=<XHTTP_SHORT_ID>&type=xhttp&path=<XHTTP_PATH URL 编码>&mode=auto#<NODE_PREFIX>-XHTTP

# VLESS + Reality + Vision（TCP）
vless://<VLESS_UUID>@<VPS_IP>:<REALITY_PORT>?encryption=none&flow=xtls-rprx-vision&security=reality&sni=<REALITY_SNI>&fp=chrome&pbk=<REALITY_PUBLIC_KEY>&sid=<REALITY_SHORT_ID>&type=tcp#<NODE_PREFIX>-Reality
```
