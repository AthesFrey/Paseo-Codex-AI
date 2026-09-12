# v3.3 验证记录

检查日期：2026-09-12。以下是交付前的静态、隔离安装和真实官方包检查；新 VPS 的 Relay、BackAPI 服务商和客户端仍需按 README 完成端到端验收。

## 已完成

- `00`–`06` 全部脚本和 `lib/common.sh` 通过 `bash -n`；`lib/local-check.py` 通过 Python 编译检查；JSON/TOML 模板均可解析。
- 从 npm 官方 registry 解析到 `@getpaseo/cli@0.8.0`、`@openai/codex@0.154.0`；PyPI 官方版本为 `uv 0.12.13`。包内 `package.json`、lockfile 和文档保持一致。
- Node.js 24.21.0 amd64 压缩包与 Node 官方 `SHASUMS256.txt` 匹配；安装脚本保留 amd64/arm64 选择和下载校验，升级脚本按官方 index 选择版本。
- 包内 lockfile 在 Node.js 24.21.0/npm 11 和 Node.js 22.23.2/npm 10 环境分别完成真实 `npm ci --omit=dev --no-audit --no-fund`；Paseo 0.8.0、Codex 0.154.0 可运行。
- Paseo 0.8.0 的实际 `PersistedConfigSchema` 接受默认配置和 `codex-bk` 派生 provider；Codex 0.154.0 使用模板执行 `--strict-config` 读取配置。
- 在隔离 home 中以前台启动 Paseo 0.8.0 daemon，`/api/health` 返回 200；`paseo provider models codex-bk --thinking` 返回 `low`、`medium`、`high`、`xhigh`、`max`，默认 `high`。
- `02-configure.sh` 和 `06-configure-backapi.sh` 均从当前终端读取 HTTPS provider 地址，自动补齐 `/v1`；重复执行会更新对应地址并保留 key、密码和其他配置。
- `06-configure-backapi.sh` 沿用当前基线的 `/srv/paseo/runtime`、`/etc/paseo` 和 `/srv/proj` 布局；wrapper、systemd drop-in、API key 文件和自定义 provider 路径不再引用旧版路径。
- `lib/local-check.py` 在存在 BackAPI 配置时检查 root:root、0600 key 文件、可执行 wrapper 和 `codex-bk` provider；不存在 BackAPI 时保持普通 3.3 安装检查。
- `00-firewall-relay-check.sh` 仅查看 nftables output 链并测试出站 HTTPS，没有添加、删除或 reload 防火墙规则；服务仍只监听 `127.0.0.1:6767`。
- 交付目录只包含脚本、模板、文档、依赖清单和校验文件，不包含 `node_modules`、缓存、日志、测试状态或凭据。

## 仍需在新 VPS 验收

- Debian 12/13 全新机器上的 apt 安装、systemd 文件保护、重启恢复和 arm64 二进制未在当前环境模拟。
- 官方 Relay 的真实出站 TLS/E2EE、手机/Windows 配对以及第三方 API 的真实 Responses API 请求需要按 README 执行 `03-pair.sh`、`04-check.sh` 和 API smoke；本地 health/schema 检查不代表服务商额度、模型参数或网络策略已经通过。
