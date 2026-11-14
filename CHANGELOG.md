# 更新记录

## v2

### 新增
- `scripts/deploy.sh`：一键部署编排。默认 `--plan` 只读（显示组件、脱敏配置、预检、每步是否修改系统；退出码 0/2），`--yes`/`--apply` 执行；`--only`/`--skip` 选组件（xray hy2 hop tuic cdn sub），`--non-interactive`（无终端时自动开启，执行必须带 `--yes`），`--set KEY=VALUE` 传入主人决定的值。按顺序复用现有脚本：gen_secrets → prepare_host → xray → hy2 → 端口跳跃 → tuic → cloudflared（不能执行时跳过并说明原因）→ 生成客户端 → 发布订阅 → status。失败即停并打印续跑命令；日志写 `/var/log/oracle-vpn-kit/`（不含秘密）；结束时只列客户端文件路径和需在云安全列表放行的端口。
- `AGENTS.md`：给 AI 代理的操作手册（前提、向主人询问的清单、权限闸门、带成功信号的步骤、回滚/卸载、排障表、机器可读 YAML）。README 顶部加指引。
- `install_xray.sh --bin-only`：只装二进制和 unit，用于先生成 Reality 密钥。
- `gen_secrets.sh` 接受 `KEY=VALUE` 参数（只填空值/占位符）；`VPS_IFACE` 按默认路由自动识别。
- `gen_subscription.py --without hy2,tuic,cdn,xhttp,reality`：没部署的组件不进订阅；只剩不支持的节点时删除旧的 `sing-box.json`。
- CI 增加 `deploy.sh --plan` 检查：用假值跑计划，并确认仓库没有任何文件被修改。
- `scripts/status.sh`：只读健康检查。服务状态、监听端口（WS 必须只在本机）、防火墙放行、端口跳跃规则及持久化、证书有效期、Xray 配置自检、订阅可取回且根目录不列文件、隧道连接数、CDN 回源、BBR、磁盘、内存；彩色 PASS/WARN/FAIL 汇总，有 FAIL 时退出码为 1；不打印任何秘密。
- `scripts/update.sh`：单独或全部升级 xray / hy2 / tuic / cloudflared；按官方校验文件验 sha256；备份旧二进制；Xray 先用新二进制自检现有配置；服务起不来自动回滚；最后跑 status。支持 `--check`、`--force`、`--version`。
- `scripts/uninstall.sh`：停用并删除 unit、只删本工具添加的防火墙与端口跳跃规则；`--purge` 先打包备份再删二进制/配置；默认需要输入 yes 确认，`--yes` 跳过；`--dry-run` 只打印命令。不碰 SSH 和其它规则。
- `tools/gen_subscription.py`：新增 sing-box 客户端配置 `sing-box.json`（1.12+ 格式）和 Base64 订阅 `v2ray.txt`；保留 Clash/Mihomo 订阅、分享链接、二维码；增加端口合法性检查。
- `tools/selftest.sh`：用随机假凭据和文档保留 IP 生成订阅，并用 mihomo / sing-box（如有）校验。
- `tools/scan_repo.py`：提交前脱敏扫描（IP、邮箱、UUID、密钥、令牌、分享链接）。
- `docker/`：可选 Docker 方案（host 网络，镜像构建时复用同一套官方下载与 sha256 校验）。
- `.github/workflows/lint.yml`：shellcheck、bash -n、py_compile、自测、脱敏与占位符检查。
- `LICENSE`（MIT）、`.shellcheckrc`、`templates/systemd/xray.service`。
- 支持 ARM（Ampere A1）实例：下载时按 `uname -m` 选择 x86_64 / aarch64 文件。

### 修复与改进
- **Reality 客户端兼容（实测发现）**：Xray-core v26.9.8+ 的 REALITY 服务端要求 ClientHello 带 X25519MLKEM768。Clash/Mihomo 订阅的 Reality 与 XHTTP 节点现在加 `support-x25519mlkem768: true`（不加时 Mihomo 连不上）；上游 sing-box（1.14.x）会删掉这个密钥共享、必然失败，因此 `sing-box.json` 默认不再包含 Reality（`SINGBOX_REALITY=1` 可加回）。
- 虚拟机端到端部署中发现并修复：Xray 临时配置文件缺 `.json` 后缀导致自检报 “Failed to get format”；root 运行 `xray -test` 会创建 root 所有的 access/error 日志，导致以 nobody 运行的 xray 起不来（新增 `xray_test`：去掉 log 段后在临时目录自检，日志目录归服务用户）；hysteria 用户没有家目录导致 unit 的 `WorkingDirectory=~` 失败；`install_xray.sh` 写死 `nogroup` 组改为按 unit 用户取组；`xray_place` 不再改动已有日志目录的属主。
- 幂等：配置未变化时重复部署不再重写任何文件（iptables 规则与已保存的一致时不再重新保存和备份 rules.v4；TUIC 证书未变化时不再重写）。
- `.env.example` 的 `CDN_DOMAIN` 改为占位符 `<CDN_DOMAIN>`，未填写时 cdn 组件会被识别为未配置。
- Xray、Hysteria2 不再通过 `curl | bash` 执行远程安装脚本，改为下载官方 Release 并校验 sha256。
- TUIC 安装自动使用官方 `.sha256sum` 校验，不再需要手动比对后交互确认；`TUIC_SHA256` 仍可用于钉死版本。
- `.env` 改为逐行解析而不是 `source`：此前只要有一个未填的 `<占位符>`（例如不用 CDN 时的隧道名），所有脚本都会因 bash 把 `<` 当成重定向而报语法错误。
- 订阅：旧版本备份不再放在网站目录里（此前可通过订阅地址访问到 `*.bak-*`）；换 `SUB_TOKEN` 后旧 token 目录会被撤下，旧地址立即失效（此前旧地址一直可用）。
- 端口跳跃：非数字的 `TUIC_PORT` 不再导致比较报错；增加 `HY2_PORT` 不得落入跳跃区间、区间起止顺序、网卡存在性检查。
- Xray 配置改在临时文件里渲染与自检，不再遗留 `config.json.new` 及其备份文件。
- systemd unit 只在内容变化时才备份和覆盖，不再每次运行都产生一个 `.bak` 文件。
- cloudflared：授权失败、隧道凭据文件缺失时给出明确提示；凭据文件以 600 权限安装。
- `prepare_host.sh`：已有任意 swap 时不再额外创建 `/swapfile`；补装 `python3`、`ca-certificates`。
- 端口变量统一做 1–65535 合法性检查。
- 实机验证后修复：`iptables -C` 在部分 iptables 版本会把匹配的规则打印到标准输出，现已全部静默（status / uninstall / open_port / 端口跳跃）。
- `status.sh`：放行规则不是本工具格式、但已被其它 ACCEPT 规则覆盖（例如合并的端口区间）时判为 PASS 并注明；完全没放行才判 FAIL。
- `uninstall.sh`：root 下 dry-run 先用只读的 `-C` 判断规则是否存在，不存在的标为「跳过」，预览与实际执行一致；精确规则删掉后如果还有其它规则放行同一端口，只提示不删除；`--purge` 删除官方 Xray-install 创建的 `xray` 用户；cloudflared 一并停用并移除 `cloudflared-update.timer`。
