# Paseo Debian 工具包

发布标识：`paseo-debian-20261125V12`。适用于 Debian 12（bookworm）和 Debian 13（trixie），支持 amd64/x86_64 与 arm64/aarch64。安装程序从 Node.js、npm registry、Paseo npm、OpenAI Codex、Anthropic Claude Code 和 Astral 官方来源获取当前稳定版；实际核验版本见[验证记录](VALIDATION.md)。

V12 是全新部署包，不迁移旧版运行时配置。V11 主机使用 `--force` 全量重装，随后重新输入 API 配置并重新配对。

## 安装

将 ZIP 上传到 VPS 并解压后，使用包内启动器安装：

```bash
unzip paseo-debian-20261125V12.zip
sudo bash paseo-debian-20261125V12/install.sh
```

V11 主机执行全量重装：

```bash
sudo bash paseo-debian-20261125V12/install.sh --force
```

也可以将 `paseo-debian-20261125V12/` 目录上传到 `AthesFrey/Paseo-Codex-AI` 仓库 `main` 分支根目录后，通过 GitHub curl 启动：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261125V12/install.sh | sudo bash
```

强制覆盖本工具管理的运行时和配置：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261125V12/install.sh | sudo bash -s -- --force
```

安装步骤按顺序执行：

```text
00-firewall-relay-check.sh -> 01-install.sh -> 02-configure.sh -> 03-pair.sh
```

安装器将工具包保存到 `/srv/paseo/deploy-kit/paseo-debian-20261125V12`。安装需要 DNS 和出站 TCP 443；Relay 不要求入站端口，脚本不会修改防火墙规则。

`--force` 会先停止 Paseo，再重建本工具管理的运行时、systemd unit、配置、密钥和应用状态。它清除 V11 托管配置、API keys 和配对身份；保留 `/srv/proj`、worktrees、非托管工具、缓存、paseo 用户及工具包源目录，自定义 systemd drop-in 也会保留。

配置阶段输入 Codex 主 API 和 Claude 中转的 HTTPS 地址、API key 与手动选择的模型列表。两个 API key 分别保存在 root 所有且权限为 `0600` 的 EnvironmentFile 中，不写入 Paseo 或 Codex 配置。Claude 中转地址输入 API 根地址；接受末尾 `/v1`，保存时去掉该后缀。模型 ID 以逗号或空格分隔，第一个 ID 设为默认模型，不自动查询 `/models`。Claude Code 使用 Anthropic 官方安装器安装 latest，并保留官方自动更新。

## 更新

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261125V12/98-update.sh
```

更新器只接受 V12 安装记录，按官方当前版本准备运行时；服务停止后再切换 Node.js、Paseo、uv 和 Codex standalone。失败时恢复原运行时及 Codex release，并恢复更新前的服务状态。Relay 检查失败会输出阶段、脱敏后的错误链和对应网络/TLS/E2EE 建议。

## 运行与检查

服务以 `paseo:paseo` 运行，在 `/srv/proj` 工作，仅监听 `127.0.0.1:6767`。Relay 使用 TLS/E2EE；本工具包使用原生 systemd，不安装或依赖 Docker。

```bash
systemctl --no-pager --full status paseo
journalctl -u paseo.service -n 80 --no-pager
ss -lntp 'sport = :6767'
curl --noproxy '*' -fsS http://127.0.0.1:6767/api/health
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261125V12/03-pair.sh
```

配对链接相当于访问凭据，仅在自己的 Paseo 客户端中使用，不要贴入日志或支持请求。

## 卸载

卸载入口可通过 GitHub curl 运行，不依赖 VPS 上保存的工具包：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261125V12/99-uninstall.sh | sudo bash -s -- --dry-run
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261125V12/99-uninstall.sh | sudo bash -s -- --yes
```

卸载会先确认服务已停止，再移除 Paseo 服务、运行时、配置及本工具管理的 Codex/Claude Code 状态；保留项目、worktrees、非托管工具、缓存、paseo 用户、其他 systemd drop-in 和工具包源目录。

## 文件

- `install.sh`：GitHub curl 启动器，下载当前仓库归档并运行安装流程。
- `00-firewall-relay-check.sh`：检查 DNS 和 Relay 出站 HTTPS。
- `01-install.sh`：安装当前官方运行时组件和 Paseo CLI 完整依赖。
- `02-configure.sh`：生成 Paseo、Codex 和 systemd 配置并保存 API keys。
- `03-pair.sh`：配对前后检查本机服务及 Relay TLS/E2EE。
- `98-update.sh`：更新运行时并在失败时回滚。
- `99-uninstall.sh`：支持本地或 curl 管道运行的卸载入口。
- `lib/`、`templates/`：共享检查、配置工具和服务模板。
- `VALIDATION.md`：本版实际执行的检查记录。
