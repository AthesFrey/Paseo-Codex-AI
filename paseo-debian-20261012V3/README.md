# paseo-debian-20261012V3：Debian AI 部署工具包

这是面向 Debian 12（bookworm）和 Debian 13（trixie）的全新安装包，支持
amd64/x86_64 与 arm64/aarch64。安装时不读取、迁移或兼容其他部署布局；每次联网安装都从官方当前元数据解析组件版本。

| 组件 | 官方来源和选择规则 |
| --- | --- |
| Node.js | Node.js 官方 `index.json` 中最新正式 LTS，归档和 `SHASUMS256.txt` |
| npm | npm 官方 registry `latest`，校验 `engines.node` 和 registry integrity |
| Paseo CLI | npm 官方 registry `@getpaseo/cli@latest`，动态生成 package-lock.json |
| Codex CLI | OpenAI 官方 standalone 安装器 `https://chatgpt.com/codex/install.sh` |
| uv | Astral GitHub 最新非预发布 release 和官方 `sha256.sum` |

实际版本以执行安装时的官方响应为准。工具包自身使用目录标识
`paseo-debian-20261012V3`，npm manifest 使用 `2026.10.12-v3`。
安装完成后，`/srv/paseo/runtime/.install-complete` 记录组件版本、来源、integrity 和 SHA256。

Hotfix 1 默认开启 Paseo 客户端 dictation，修复客户端麦克风听写被模板关闭的问题；voice mode 仍关闭。

## 首次安装

保持 root SSH 终端，以便输入 API key、管理密码和显示配对信息：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261012V3/install.sh | sudo bash
```

入口会验证工具包 `SHA256SUMS`，安装 Relay 检查依赖，然后依次运行：

```text
00-firewall-relay-check.sh -> 01-install.sh -> 02-configure.sh -> 03-pair.sh
```

工具包会保存到 `/srv/paseo/deploy-kit/paseo-debian-20261012V3`。使用 ZIP 时，解压后在包目录内执行 `sudo bash ./install.sh`，入口会使用当前目录中的文件。

## 强制全新覆盖

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261012V3/install.sh | sudo bash -s -- --force
```

`--force` 停止服务并删除本工具包托管的 runtime、`/etc/paseo`、Paseo/Codex 状态、密钥和 systemd unit，再按官网当前版本重建。它保留 `/srv/proj`、`/srv/paseo/worktrees`、其他 `/srv/paseo/tools` 内容、缓存和部署包源目录。

## 单独更新组件

首次安装完成后，可以在不重建配置和用户数据的情况下更新组件：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261012V3/98-update.sh | sudo bash
```

`98-update.sh` 只接受 paseo-debian-20261012V3 的当前目录布局。它在 `/srv/paseo/cache/tmp` 中准备并校验 Node.js LTS、npm、Paseo、Codex 和 uv，动态重建 native npm 依赖，然后短暂停机替换运行时。配置、API key、systemd unit、项目和 worktree 会在更新前后做内容、属主、权限和目录 inode 校验；health 检查失败时恢复旧运行时和 Codex 链接。

## 路径和服务

| 路径 | 用途 |
| --- | --- |
| `/srv/paseo/runtime` | root 管理的 Node、npm、Paseo、uv、Relay 检查程序和运行时依赖 |
| `/srv/paseo/tools/bin/codex` | OpenAI 官方 standalone Codex 管理链接 |
| `/srv/paseo/.codex` | Codex TOML、standalone releases 和 Agent 模板 |
| `/srv/paseo/.paseo` | Paseo v1 配置、daemon 身份、会话和配对状态 |
| `/srv/paseo/worktrees` | Paseo 工作树根目录 |
| `/srv/paseo/cache` | npm、uv、Python、Go 和 Playwright 缓存 |
| `/srv/proj` | daemon 工作目录和用户项目根目录 |
| `/etc/paseo/runtime.env` | 非机密服务环境变量 |
| `/etc/paseo/hahaapi.env` | 主 API key，root:root、0600 |
| `/etc/paseo/backapi.env` | 可选 BackAPI key，root:root、0600 |

`paseo.service` 以 `paseo:paseo` 运行，工作目录为 `/srv/proj`，只监听 `127.0.0.1:6767`。Relay 使用 TLS/E2EE；服务端 dictation 默认开启，voice mode 和自托管 Web UI 关闭。Paseo 手机/浏览器客户端里的麦克风听写还需要客户端获得麦克风权限。默认本地 STT 模型是英文模型，首次启用后由 Paseo 在后台下载；中文听写需要另配兼容的 STT 服务，主 API 的聊天地址或 key 不代表它支持音频转写。手机键盘自带的语音输入由系统和客户端输入框决定，不由 Paseo 服务端设置控制。Docker 不安装，也不是安装步骤或运行时依赖。

已用本工具早期配置部署的实例不会被 `98-update.sh` 改写配置。要在现有实例开启 Paseo 客户端的麦克风听写，请把 `/srv/paseo/.paseo/config.json` 中 `features.dictation.enabled` 改为 `true`，然后运行 `sudo systemctl restart paseo`。不要为此开启 `features.voiceMode`。

## 配置和启动

配置脚本会生成当前 Paseo v1 JSON 和 Codex TOML。输入主 API HTTPS 地址、`HAHA_API_KEY` 和手动模型 ID；第一个模型是默认模型。随后可以配置 BackAPI、自己的地址、key 和模型 ID。API key 只通过 systemd EnvironmentFile 提供，不写入 JSON、TOML 或 wrapper。

单独运行配置和配对：

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261012V3/02-configure.sh
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261012V3/03-pair.sh
```

每个模型都会提供 `low`、`medium`、`high`、`xhigh`、`max` 五档 thinking options。配置脚本会调用当前 Paseo CLI 重新解析配置、设置管理密码、校验 systemd、启动服务并执行本地 health 检查。配对脚本执行本机和 Relay TLS/E2EE 验收，不调用模型 API。

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
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261012V3/99-uninstall.sh --dry-run
```

执行卸载：

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261012V3/99-uninstall.sh --yes
```

卸载只删除本工具包托管的服务、runtime、配置、Codex standalone 状态和管理链接；保留项目、worktrees、其他工具、缓存、`paseo` 用户和部署包源目录。

## 文件清单

- `install.sh`：下载、校验并运行多步骤流程；转发 `--force`
- `00-firewall-relay-check.sh`：只读出站网络检查
- `01-install.sh`：动态安装 Node.js LTS、npm、Paseo、Codex 和 uv
- `02-configure.sh`：当前 Paseo v1、模型输入、HahaAPI、可选 BackAPI、密码和 systemd
- `03-pair.sh`：当前 CLI 配对和 Relay 验收
- `98-update.sh`：不重建用户数据的官方当前组件更新
- `99-uninstall.sh`：删除本工具包托管资源并保留用户数据
- `apps/package.json`：仅声明 `@getpaseo/cli: latest`
- `lib/`：公共降权函数、模型输入/配置写入、本地验收和 Relay 检查
- `templates/`：当前配置、systemd、环境和 Agent 模板
- `VALIDATION.md`：交付验证记录
- `SHA256SUMS`：逐文件 SHA256
