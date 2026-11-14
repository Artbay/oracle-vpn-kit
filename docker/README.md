# 可选：Docker 方案

> **这是可选的替代方案。** 默认推荐仓库根目录 README 里的 systemd 步骤。两种方案二选一，不要同时运行。

适合已经习惯用 Docker 管理服务、或想让核心程序与系统隔离的人。

## 和 systemd 方案的区别

| | systemd（默认） | Docker（可选） |
|---|---|---|
| 二进制来源 | 官方 Release + sha256 校验 | 同一套下载与校验（构建镜像时复用 `scripts/lib.sh`），不依赖第三方镜像 |
| 网络 | 宿主机 | `network_mode: host`，性能与 systemd 相同 |
| 端口跳跃 / BBR / 防火墙 | 宿主机 | 仍在宿主机（`scripts/setup_port_hopping.sh`、`docker/prepare.sh`） |
| Cloudflare 隧道、订阅服务 | systemd | 仍用 systemd 脚本 |
| 升级 | `scripts/update.sh` | `docker compose build --no-cache && docker compose up -d` |
| 健康检查 | `scripts/status.sh` | `docker compose ps`、`docker compose logs`；`status.sh` 的端口/规则/订阅部分同样适用 |

## 步骤

```bash
# 宿主机已装好 Docker 与 compose 插件（参考 Docker 官方文档用 apt 源安装）
cp .env.example .env && vi .env && bash scripts/gen_secrets.sh
# Reality 密钥对：没有装 xray 时可用镜像生成
#   docker compose -f docker/compose.yaml build && docker run --rm oracle-vpn-kit-cores:local xray x25519
#   把输出手动填进 .env 的 REALITY_PRIVATE_KEY / REALITY_PUBLIC_KEY
sudo bash scripts/prepare_host.sh
sudo bash docker/prepare.sh              # 渲染配置到 docker/conf/（已 gitignore）、证书、放行端口
sudo bash scripts/setup_port_hopping.sh  # Hy2 端口跳跃
cd docker && sudo docker compose up -d --build
sudo docker compose ps
# 可选：CDN 隧道与订阅仍用 systemd 脚本
sudo bash ../scripts/install_cloudflared_tunnel.sh
python3 ../tools/gen_subscription.py --env ../.env --out ../out && sudo bash ../scripts/serve_subscription.sh
```

固定版本：在 `.env` 或命令前设置 `XRAY_VERSION=v26.x.x HY2_VERSION=app/v2.x.x TUIC_VERSION=1.0.0`。

## 安全说明

- 容器只读根文件系统、`no-new-privileges`、丢弃全部能力；hysteria/tuic 以 `65534` 用户运行，xray 只保留 `NET_BIND_SERVICE`（绑定 443）。
- `docker/conf/` 含私钥和密码，已在 `.gitignore` 中，切勿提交或外发。
- 停用：`docker compose down`；端口规则可用 `scripts/uninstall.sh --dry-run` 先查看再删除。
