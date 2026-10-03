# paseo-debian-20261002-v6.1fix2：Debian 部署工具包

这是面向 Debian 12（bookworm）和 Debian 13（trixie）的全新安装包，支持
x86_64/amd64 与 arm64/aarch64。v6.1fix2 只按安装时的官方当前响应部署，不读取或迁移旧配置，也不携带历史 lockfile、旧版本分支或兼容迁移代码。

| 组件 | 官方来源和安装方式 | 2026-10-02 联网解析示例 |
| --- | --- | --- |
| Node.js | Node.js Current `index.json`、归档和 `SHASUMS256.txt` | 26.10.0 |
| npm | Node 自带 npm 安装 registry `latest` | 12.2.0 |
| Paseo CLI | npm 官方 registry `@getpaseo/cli@latest` | 0.10.2 |
| Codex CLI | OpenAI 官方 standalone 安装器 `https://chatgpt.com/codex/install.sh` | 0.160.0 |
| uv | Astral GitHub 最新非预发布 release、`sha256.sum` | 0.12.21 |

实际版本以安装时的官方响应为准。发布目录标识为 `v6.1fix2`；npm manifest 使用 semver 合法的 `2026.10.2-v6.1fix2`。`01-install.sh` 会写入版本、来源、npm/Paseo integrity 以及 Node、Codex、uv 的 SHA256 到 `/srv/paseo/runtime/.install-complete`。

## 部署入口

保持 root SSH 终端，以便输入 API key、Paseo 管理密码并显示配对信息：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261002-v6.1fix2/install.sh | sudo bash
```

入口脚本校验 GitHub 源码归档中的 `SHA256SUMS`，然后依次运行 `00 -> 01 -> 02 -> 03`。包源会保存在 `/srv/paseo/deploy-kit/paseo-debian-20261002-v6.1fix2`。

使用 ZIP 时，解压后在目录内执行 `sudo bash ./install.sh`；入口会先校验并使用当前目录中的 v6.1fix2 包，不要求再次从 GitHub 下载同一包。

强制全新覆盖 v6.1fix2 托管运行时：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261002-v6.1fix2/install.sh | sudo bash -s -- --force
```

`--force` 停止服务并删除 v6.1fix2 的 runtime、`/etc/paseo`、Paseo/Codex 状态、密钥和 systemd unit，再从官方当前版本重建。它保留 `/srv/proj`、`/srv/paseo/worktrees`、其他 `/srv/paseo/tools` 内容、缓存和部署包源目录。

## 路径和服务

| 路径 | 用途 |
| --- | --- |
| `/srv/paseo/runtime` | root 管理的 Node、npm、Paseo、uv、Relay 检查程序和运行时依赖 |
| `/srv/paseo/tools/bin/codex` | OpenAI 官方 standalone Codex 管理链接 |
| `/srv/paseo/.codex` | Codex 当前 TOML、standalone releases 和 `AGENTS.md` |
| `/srv/paseo/.paseo` | Paseo v1 配置、daemon 身份、会话和配对状态 |
| `/srv/paseo/worktrees` | Paseo 工作树根目录 |
| `/srv/paseo/cache` | npm、uv、Python、Go 和 Playwright 缓存 |
| `/srv/proj` | daemon 工作目录和用户项目根目录 |
| `/etc/paseo/runtime.env` | 非机密服务环境变量 |
| `/etc/paseo/hahaapi.env` | 主 API key，root:root、0600 |
| `/etc/paseo/backapi.env` | 可选 BackAPI key，root:root、0600 |

`paseo.service` 以 `paseo:paseo` 运行，工作目录为 `/srv/proj`，只监听
`127.0.0.1:6767`。Relay 使用 TLS/E2EE，Web UI、dictation 和 voice mode 默认关闭。Docker 不安装，也不是任何步骤或运行时依赖。

## 安装步骤

`00-firewall-relay-check.sh` 只读取 nftables output 链并访问 `https://relay.paseo.sh/`，不添加、删除或重载防火墙规则。

`01-install.sh` 会：

- 下载并验证 Node.js Current 官方归档；先用 Node 自带 npm 安装 npm registry `latest`，检查其 `engines.node` 与 Node 兼容。
- 用当前 npm 将 `@getpaseo/cli@latest` 和完整依赖树安装到 `/srv/paseo/runtime/apps`，生成安装时的 `package-lock.json`。
- 动态读取 `npm install-scripts ls --json`，仅临时允许当前报告的待构建包（例如 `esbuild`、`node-pty`、`msgpackr-extract`），执行 native rebuild 后删除项目 `.npmrc`。
- 通过统一的 `run_as_paseo` 进入 `/srv/proj`，显式设置 `HOME`、`CODEX_HOME`、缓存和 PATH，再执行 OpenAI 官方 Codex standalone 安装器。这会避免从不可访问的 `/root` 恢复工作目录。
- 下载并验证 uv 官方归档和 checksum；所有临时文件只写入 `/srv/paseo/cache/tmp`。

安装成功输出 `STEP1_OK`。

## 配置和启动

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261002-v6.1fix2/02-configure.sh
```

脚本生成当前 Paseo v1 JSON 和 Codex TOML。输入主 API HTTPS 地址及 `HAHA_API_KEY` 后，脚本不会联网获取模型目录，而是提示你输入模型 ID。多个模型使用逗号或空格分隔，第一个 ID 自动作为主 API 默认模型。然后可选配置 BackAPI；BackAPI 使用自己的地址、key 和手动输入的模型 ID，第一个 ID 作为 BackAPI 默认模型。重新运行配置步骤时可选择复用或重新输入已保存的 key。

每个手动输入的模型都会写入 Paseo provider 的 `models`，并提供 `low`、`medium`、`high`、`xhigh`、`max` 五个难度档；主 API 默认值同时写入 Codex TOML 和 metadata generation。API key 只通过 systemd EnvironmentFile 提供，不写入 JSON、TOML 或 wrapper。BackAPI 继续使用当前 provider override schema 和 standalone Codex wrapper。脚本调用当前 `paseo daemon config get` 重新解析配置，再设置管理密码、校验 unit、启动服务并执行本地验收，成功输出 `STEP2_OK`。

## 配对和最终验收

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261002-v6.1fix2/03-pair.sh
```

脚本会动态检查 Node、npm、Paseo、Codex、uv、npm lockfile、native 依赖、当前配置、权限、systemd、环境变量、回环监听和 health，然后执行官方 `paseo daemon pair --relay` 显示二维码/链接。客户端完成配对并按 Enter 后，再次执行本机和 Relay TLS/E2EE 状态检查，成功输出 `CHECK_OK`。检查不会调用模型 API。

常用排查命令：

```bash
systemctl --no-pager --full status paseo
journalctl -u paseo.service -n 80 --no-pager
ss -lntp 'sport = :6767'
curl --noproxy '*' -fsS http://127.0.0.1:6767/api/health
```

## 卸载

先查看范围：

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261002-v6.1fix2/99-uninstall.sh --dry-run
```

执行卸载：

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261002-v6.1fix2/99-uninstall.sh --yes
```

卸载只删除 v6.1fix2 托管的服务、runtime、配置、Codex standalone 状态和管理链接；保留项目、worktrees、其他工具、缓存、paseo 用户和部署包源目录。

## 文件清单

- `install.sh`：下载、校验并运行 v6.1fix2 多步骤流程；转发 `--force`
- `00-firewall-relay-check.sh`：只读出站网络检查
- `01-install.sh`：动态安装 Node/npm/Paseo/Codex/uv；`--force` 重建托管状态
- `02-configure.sh`：当前 Paseo v1、手动模型输入、HahaAPI、可选 BackAPI、密码和 systemd
- `03-pair.sh`：当前 CLI 配对、动态版本检查和 Relay 验收
- `99-uninstall.sh`：删除 v6.1fix2 托管资源并保留用户数据
- `apps/package.json`：仅声明 `@getpaseo/cli: latest`
- `lib/`：公共降权函数、模型输入/配置写入、本地验收和官方客户端 Relay 检查
- `templates/`：当前配置、systemd、环境和 Agent 模板
- `VALIDATION.md`：交付验证记录
- `SHA256SUMS`：逐文件 SHA256
