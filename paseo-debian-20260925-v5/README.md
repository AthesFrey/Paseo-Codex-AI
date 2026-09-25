# paseo-debian-20260925-v5：Debian 部署工具包

本包基于 2026-09-25 的固定版本构建，面向 Debian 12（bookworm）和 Debian 13（trixie），支持 amd64/x86_64 与 arm64/aarch64。运行时版本固定，不会在安装时自动追随后续发布。

| 组件 | 固定版本 | 官方来源 |
| --- | --- | --- |
| Node.js | 26.10.0 Current；npm 11.19.1 | Node.js 官方发布索引与 `SHASUMS256.txt` |
| Paseo CLI | `@getpaseo/cli@0.9.2` | npm Registry 与 Paseo GitHub release |
| Codex CLI | `@openai/codex@0.157.0` | npm Registry；lockfile 固定 Linux x64/arm64 原生包 |
| uv | 0.12.19 | Astral uv release；安装时校验 Linux GNU 压缩包 SHA256 |

Node.js 26.10.0 是 Current 正式版，不是 LTS 线。npm 依赖由随包的 manifest 和 lockfile 固定。

## 目录和服务

| 路径 | 用途 |
| --- | --- |
| `/srv/paseo/runtime` | root 管理的 Node、Paseo、Codex、uv 和 Relay 检查程序 |
| `/srv/paseo/.paseo` | Paseo 配置、服务身份、会话和配对状态 |
| `/srv/paseo/.codex` | Codex 配置和全局 `AGENTS.md` |
| `/srv/paseo/worktrees` | Paseo 管理的 Git 工作树 |
| `/srv/paseo/deploy-kit/paseo-debian-20260925-v5` | 从 GitHub 下载并保留的部署包源文件 |
| `/srv/paseo/tools` | 用户级工具 |
| `/srv/paseo/cache` | 临时、npm、pip、uv、Go 和 Playwright 缓存；安装验收后保留 |
| `/srv/proj` | 默认项目根目录 |
| `/etc/paseo/runtime.env` | 非机密服务环境 |
| `/etc/paseo/hahaapi.env` | 主 API key，root:root、0600 |
| `/etc/paseo/backapi.env` | 可选 BackAPI key，root:root、0600 |

`paseo.service` 以 `paseo:paseo` 运行，工作目录为 `/srv/proj`。daemon 固定监听 `127.0.0.1:6767`，Relay 使用 TLS，Web UI 默认关闭。部署使用官方 npm CLI 和 systemd，不依赖 Docker，也不需要开放 6767 入站端口。

## Git 和 Paseo 项目

Paseo 的 Project 可以是普通目录或 Git 仓库；workspace 可使用 `local` 或 Git `worktree` 隔离。部署配置只设置 worktree 的存放目录，不会为所有新项目自动运行 `git init`。日常对话可以留在普通本地目录；代码项目按需使用 Git，worktree 只用于已有 Git 仓库。

## 一条命令部署

要求：Debian 12/13、root SSH 终端、至少 2 vCPU、2 GiB RAM 和 8 GiB 可用磁盘。保持交互式终端以输入 API 凭据、管理密码并完成客户端扫码：

将本目录完整提交到 GitHub。保持交互式 SSH 终端，在 VPS 上运行：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20260925-v5/install.sh | sudo bash
```

`install.sh` 从 GitHub `main` 下载源码归档，从中取出 v5 工具包并校验包内 `SHA256SUMS`。Relay 检查和运行时安装成功后，脚本将工具包保存在 `/srv/paseo/deploy-kit/paseo-debian-20260925-v5`，再交互配置服务、配对客户端并执行最终验收。

### Relay 和服务检查

`00-firewall-relay-check.sh` 只读取 nftables output 链并访问 `https://relay.paseo.sh/`，不创建、删除或重载防火墙规则。通过标记为 `FIREWALL_RELAY_CHECK_OK`。脚本要求 DNS、TCP 443 和已建立连接回包可出站。

### 安装固定运行时

`01-install.sh` 安装 Debian 开发依赖、创建 `paseo` 服务账户、校验 Node 官方 SHA256、按 lockfile 执行 `npm ci --omit=dev`，并下载校验 uv 官方预编译包。npm manifest 只批准固定版本的 `esbuild` 与 `node-pty` 安装脚本。脚本创建服务所需缓存目录，均为 `paseo:paseo`、0700。

若要重建当前 Paseo 托管部署：

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20260925-v5/01-install.sh --force
```

强制覆盖会停止服务并清除托管运行时、systemd unit/drop-in、`/etc/paseo`、`/srv/paseo/.paseo`、`/srv/paseo/.codex` 和生成的 `.profile`。它会丢弃 Paseo 会话/配对身份、Codex 登录状态及已保存密钥；之后需重新执行配置。它保留 `/srv/proj`、`/srv/paseo/worktrees`、`/srv/paseo/tools`、`/srv/paseo/cache` 和 `/srv/paseo/deploy-kit`。普通安装检测到已有托管路径时会停止。

### 配置 API 和服务

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20260925-v5/02-configure.sh
```

保持交互式 root 终端。按提示输入主 API HTTPS 地址和 `HAHA_API_KEY`，然后选择是否配置 BackAPI。选择配置时再输入 BackAPI HTTPS 地址和 `BACKAPI_API_KEY`；地址可省略末尾 `/v1`。密钥输入不回显，只写入 root:root、0600 环境文件，不进入 JSON、TOML 或命令行。

BackAPI 作为 `Codex_bk` 独立 provider 加入 Paseo，不替换主 API。跳过时不会创建 BackAPI 密钥、wrapper 或 systemd drop-in。Codex 默认模型为 `gpt-6-astra`，思考选项为 `low`、`medium`、`high`、`xhigh`、`max`，默认 `high`。通过标记：`STEP2_OK`；启用 BackAPI 时另有 `BACKAPI_CONFIG_OK`。

### 客户端配对和最终验收

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20260925-v5/03-pair.sh
```

脚本检查固定组件版本、运行用户、目录权限、systemd unit、关键环境路径、回环监听、本机 health、密钥文件权限和 Relay 状态请求。通过后提示输入 Paseo 管理密码并输出配对二维码/链接。客户端完成配对并按 Enter 后，脚本再次检查本机与 Relay，成功时输出 `CHECK_OK`。此流程不会清理缓存，也不会为缓存清理停止或重启服务。

系统级排查命令：

```bash
systemctl --no-pager --full status paseo
journalctl -u paseo.service -n 80 --no-pager
ss -lntp 'sport = :6767'
curl --noproxy '*' -fsS http://127.0.0.1:6767/api/health
```

真实 API smoke test 会消耗 provider 额度；从客户端发起小任务验证。不要把 API key、密码、完整环境变量或配对链接写入命令行、日志或项目文件。

## Codex 配置检查

不调用模型即可验证 Codex 当前版本能解析配置并启动 app-server 命令：

```bash
runuser -u paseo -- env -i HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex \
  PATH=/srv/paseo/runtime/apps/node_modules/.bin:/srv/paseo/runtime/node/bin:/srv/paseo/runtime/uv/bin:/usr/bin:/bin \
  codex --strict-config --help
runuser -u paseo -- env -i HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex \
  PATH=/srv/paseo/runtime/apps/node_modules/.bin:/srv/paseo/runtime/node/bin:/srv/paseo/runtime/uv/bin:/usr/bin:/bin \
  codex app-server --help
```

## 卸载

先查看范围：

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20260925-v5/99-uninstall.sh --dry-run
```

执行卸载：

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20260925-v5/99-uninstall.sh --yes
```

卸载会停止并移除 `paseo.service`、drop-in、`/etc/paseo`、运行时、工具缓存、`.codex`、`.paseo` 以及 `paseo` 账户和用户组。它会删除 `/srv/paseo/cache`，保留 `/srv/proj`、`/srv/paseo/worktrees`、项目文件和 `/srv/paseo/deploy-kit` 部署包源目录。

## 文件清单

- `00-firewall-relay-check.sh`：只读出站网络检查
- `01-install.sh`：固定版本运行时安装；`--force` 重建托管状态
- `02-configure.sh`：主 API、可选 BackAPI、Paseo 配置和 systemd 服务
- `03-pair.sh`：配对、完整验收和 Relay 复验
- `99-uninstall.sh`：当前部署卸载
- `apps/`：固定 npm manifest 和 lockfile
- `lib/`：公共 shell 函数、本地检查和 Relay 检查
- `templates/`：当前配置、systemd 和环境模板
- `VALIDATION.md`：交付验证记录
- `SHA256SUMS`：逐文件 SHA256
