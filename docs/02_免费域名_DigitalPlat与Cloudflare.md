# 02 免费域名：DigitalPlat FreeDomain + Cloudflare

> 核对时间：2026 年下半年。免费域名平台的规则变化较快，**以官方 Dashboard 当前显示为准**。CDN 节点才需要域名；只用 Hy2/TUIC/Reality 可以跳过本篇。

## 1. DigitalPlat FreeDomain 是什么

- 提供多个免费公共后缀下的二级域名（可选后缀列表会变，以 Dashboard 为准）。也可以用任何你已有的域名，只要能托管到 Cloudflare。
- 官方仓库：<https://github.com/DigitalPlatDev/FreeDomain>
- **官方注册入口（Dashboard）**：<https://dash.domain.digitalplat.org/>
- 官方教程（英文）：[documents/tutorial](https://github.com/DigitalPlatDev/FreeDomain/tree/main/documents/tutorial/platform)
- 平台也可能提供自带 DNS；本方案用 **Cloudflare** 托管 DNS，因为 CDN 节点和 Tunnel 都依赖 Cloudflare。

> 提醒：搜索结果里有不少镜像站/仿冒站，**只从上面的官方仓库或 Dashboard 链接进入**。

## 2. 注册账号（官方教程 1.1）

来源：[1.1 Account Registration](https://github.com/DigitalPlatDev/FreeDomain/blob/main/documents/tutorial/platform/1.1-account-registration.md)

- 准备：长期可用的邮箱、真实姓名、手机号、完整联系地址、独立密码（存在密码管理器里）。
- 官方要求**如实填写**，不要用虚构信息；阅读 ToS、隐私政策、可接受使用政策（AUP）。
- 能开多因素认证就开。

> **未核实**：第三方教程提到注册后需要 **GitHub 账号绑定/授权**作为验证（有的写成「Sign in with GitHub」）；官方教程当前未写明是否强制 GitHub 或 KYC。实际以 Dashboard 提示为准——如果要求 GitHub 验证，用你自己的 GitHub 账号授权即可。

## 3. 注册域名（官方教程 1.2）

来源：[1.2 Domain Registration](https://github.com/DigitalPlatDev/FreeDomain/blob/main/documents/tutorial/platform/1.2-domain-registration.md)

1. 先看 Dashboard 公告（后缀、暂停注册、配额、价格、续期窗口都可能变）。
2. **建议先在 Cloudflare 添加站点拿到 NS**（见第 5 节），因为注册时可能就要求填 NS。
3. Dashboard → **Register** → 输入前缀、选后缀 → **Check availability** → 核对完整域名、NS、配额/费用 → 提交。
4. 在 **Domain List** 里确认状态和**到期日**，私下记录。

## 4. 每年续期（重要）

- 官方（[1.4 Status and Renewal](https://github.com/DigitalPlatDev/FreeDomain/blob/main/documents/tutorial/platform/1.4-status-and-renewal.md)）：Dashboard 是注册状态和到期日的唯一准绳；续期窗口、费用、配额规则可能变化；建议设置**到期前 90/60/30/7 天**提醒；续期只提交一次，提交后确认新的到期日。
- 第三方教程普遍说明：免费域名**注册周期 1 年，到期前约 30 天内在 Dashboard 点 Renew 免费续期**——**未在官方文档中找到原文，按 Dashboard 实际显示为准**。
- **域名过期 = CDN 节点全部失效**（Hy2/TUIC/Reality 不受影响）。

## 5. Cloudflare 免费账号与托管

1. 注册 <https://dash.cloudflare.com/sign-up>（免费）。
2. **Add a domain / 添加站点**：输入完整域名（如 `<你的域名>`），选 **Free** 计划。参考：[Add a site](https://developers.cloudflare.com/fundamentals/manage-domains/add-site/)
3. Cloudflare 会分配**两条 NS**（形如 `xxx.ns.cloudflare.com`），这两条是自动分配、不能自选的。参考：[Change your nameservers](https://developers.cloudflare.com/dns/zone-setups/full-setup/setup/)
4. 回 DigitalPlat Dashboard，把**两条 NS 主机名原样**填进去（不要填 IP）。参考：[1.3 Connect Nameservers](https://github.com/DigitalPlatDev/FreeDomain/blob/main/documents/tutorial/platform/1.3-connect-nameservers.md)
5. 等待 Cloudflare 显示 **Active**（几分钟到几小时不等）。可用 `dig NS <你的域名>` 检查是否已经是 Cloudflare 的 NS。

## 6. Cloudflare 里要做的设置

- **SSL/TLS → Overview → 加密模式 Full**。参考：[Full mode](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full/)
  - 经验：CDN 节点走 Tunnel，回源由 cloudflared 处理；本方案实际使用 Full 正常工作。**不要用 Flexible**。
- **Network → WebSockets：开启**（VLESS+WS 需要）。参考：[WebSockets](https://developers.cloudflare.com/network/websockets/)
- **DNS 记录不用手动建**：`scripts/install_cloudflared_tunnel.sh` 里的 `cloudflared tunnel route dns <隧道名> <CDN_DOMAIN>` 会自动创建一条**已代理（橙色云）的 CNAME**，指向 `<隧道ID>.cfargotunnel.com`。参考：[Tunnel DNS records](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/dns/)
- 首次运行脚本时，`cloudflared tunnel login` 会打印一个授权链接：**你本人**在浏览器打开、登录 Cloudflare、选择这个域名授权；生成的 `cert.pem` 只留在服务器（600 权限）。

## 7. 注意

- **不要改动 zone 里不是你为本方案创建的 DNS 记录和设置**（包括平台自动生成或你以前加的记录）；本方案只新增 `CDN_DOMAIN` 这一条 CNAME。
- 删除隧道时 `cloudflared tunnel delete` **不会**自动删 DNS 记录，需要去面板手动删那一条 CNAME。
- 给域名续期设日历提醒；Cloudflare 账号开两步验证。
- 遵守 DigitalPlat 与 Cloudflare 的服务条款与可接受使用政策。
