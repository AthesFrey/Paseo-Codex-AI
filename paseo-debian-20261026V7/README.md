# Paseo Debian 工具包

发布标识：`paseo-debian-20261026V7`。适用于 Debian 12（bookworm）和 Debian 13（trixie），支持 amd64/x86_64 与 arm64/aarch64。安装程序从官方源获取 Node.js 当前 LTS、npm registry latest、Paseo CLI latest、OpenAI Codex standalone 和 Astral uv 稳定版。实际核验结果见[验证记录](VALIDATION.md)。

## 安装

将 `paseo-debian-20261026V7/` 目录上传到 `AthesFrey/Paseo-Codex-AI` 仓库 `main` 分支根目录后，在 Debian VPS 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261026V7/install.sh | sudo bash
```

强制覆盖本工具管理的运行时和配置：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261026V7/install.sh | sudo bash -s -- --force
```

安装步骤按顺序执行：

```text
00-firewall-relay-check.sh -> 01-install.sh -> 02-configure.sh -> 03-pair.sh
```

安装器将工具包保存到 `/srv/paseo/deploy-kit/paseo-debian-20261026V7`。安装需要 DNS 和出站 TCP 443；Relay 不要求入站端口，脚本不会修改防火墙规则。

`--force` 会先停止 Paseo，再重建本工具管理的运行时、systemd unit、配置、密钥和应用状态。它保留 `/srv/proj`、worktrees、非托管工具、缓存、paseo 用户及工具包源目录；自定义 systemd drop-in 会保留。

## 更新

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261026V7/98-update.sh
```

更新器解析官方当前版本并准备替换文件。运行时和 Codex standalone 只会在服务停止后切换；停服失败或服务仍 active 时不会修改在线运行时。若配置、服务 health 或 Relay TLS/E2EE 检查失败，会回滚运行时、Codex 选择和更新前的服务状态。

## 运行与检查

服务以 `paseo:paseo` 运行，在 `/srv/proj` 工作，仅监听 `127.0.0.1:6767`。Relay 使用 TLS/E2EE。API key 存放在 root 所有且权限为 `0600` 的 EnvironmentFile 中，不写入 Paseo 或 Codex 配置。

```bash
systemctl --no-pager --full status paseo
journalctl -u paseo.service -n 80 --no-pager
ss -lntp 'sport = :6767'
curl --noproxy '*' -fsS http://127.0.0.1:6767/api/health
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261026V7/03-pair.sh
```

配对链接相当于访问凭据，仅在自己的 Paseo 客户端中使用，不要贴入日志或支持请求。

Paseo 以原生 systemd 服务运行；本工具包不安装或依赖 Docker。

## 卸载

卸载入口可通过 GitHub curl 运行，不依赖 VPS 上保存的工具包：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261026V7/99-uninstall.sh | sudo bash -s -- --dry-run
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261026V7/99-uninstall.sh | sudo bash -s -- --yes
```

卸载会先列出托管资源；服务无法停止时会保留文件并退出。它移除 Paseo 服务、运行时、配置和本工具管理的 Codex 状态，保留项目、worktrees、非托管工具、缓存、paseo 用户、其他 service drop-in 及工具包源目录。

## 文件

- `install.sh`：GitHub curl 启动器，下载当前仓库归档并运行安装流程。
- `00-firewall-relay-check.sh`：检查 DNS 和 Relay 出站 HTTPS。
- `01-install.sh`：安装当前官方运行时组件和 Paseo CLI 完整依赖。
- `02-configure.sh`：生成 Paseo、Codex 和 systemd 配置。
- `03-pair.sh`：配对前后检查本机服务及 Relay TLS/E2EE。
- `98-update.sh`：更新运行时并在失败时回滚。
- `99-uninstall.sh`：支持本地或 curl 管道运行的卸载入口。
- `lib/`、`templates/`：共享检查、配置工具和服务模板。
- `AGENTS.md`：本工具包的开发与发布约定。
- `VALIDATION.md`：本版实际执行的检查记录。
