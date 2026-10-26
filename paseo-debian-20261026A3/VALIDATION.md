# paseo-debian-20261026A3 验证记录

记录日期：2026-10-26。版本策略是在安装时读取官方最新 Node.js LTS、npm registry latest、Paseo CLI latest、OpenAI Codex standalone 安装器及 Astral uv 官方安装器；下列版本是本次联网检查时解析到的版本：Node.js 24.22.1、npm 12.2.1、Paseo 0.13.0、Codex 0.164.0、uv 0.13.5。

A3 基于 A2，部署行为保持不变；本次主要调整发布标识和文档。以下 A2 功能测试作为沿用基线记录，不表示本次对真实 VPS 重新执行了安装。

## A2 功能基线记录

- 全部 Bash 脚本通过 `bash -n`；Python 文件通过 AST 解析；Relay JavaScript 通过 `node --check`；JSON 和 TOML 文件可解析。
- 下载并展开 Node.js 官方 `v24.22.1` x64 归档，确认 Node.js 版本；在隔离前缀中将归档内 npm 更新到 registry latest `12.2.1`，安装后版本匹配。npm 最新版声明的 Node 范围为 `^22.22.2 || ^24.15.0 || >=26.0.0`，包含 `24.22.1`。
- 当前机器实际运行验证为 x64。另确认 Node.js `v24.22.1` arm64 官方归档可用、uv `0.13.5` 发布包含 aarch64 Linux 归档，Codex 官方安装器识别 `aarch64`；本次未运行 ARM64 二进制。
- 在 `/srv/paseo/cache/debianvps/` 隔离目录安装 `@getpaseo/cli@latest`，解析到 Paseo `0.13.0`。npm 报告三个待执行安装脚本，按部署流程临时允许 `esbuild`、`msgpackr-extract` 和 `node-pty` 后 rebuild 成功，临时 `.npmrc` 已删除。
- 使用 Paseo `0.13.0` CLI 解析基础 v1 配置和生成的主 API、BackAPI 双 provider 配置；JSON、TOML、默认模型和 API URL 检查通过。
- 在隔离目录运行当前 OpenAI 官方 Codex standalone 安装器，解析并安装 `0.164.0`；`tools/bin/codex` 指向 `CODEX_HOME/packages/standalone/releases/.../bin/codex`。运行 Astral 官方 uv 安装器并验证 `uv 0.13.5`。
- 对隔离副本运行 `01-install.sh` force 预检：官方 standalone 命令软链接获准进入后续安装；未知软链接、普通文件和目录均在清理前拒绝，普通文件和目录没有被删除。
- 对隔离副本运行 force 清理阶段：托管运行时、配置、密钥目录、Codex 链接、systemd unit 和本工具 BackAPI drop-in 被移除；用户自定义 drop-in、项目、worktrees、其他工具、缓存和工具包源目录保留。
- 对隔离副本运行卸载 dry-run 和确认卸载：dry-run 未修改文件；确认卸载只移除托管资源并保留用户 drop-in 与数据目录。
- 验证部署包目录比较可接受相同内容、拒绝内容差异；权限规范化将目录设为 `0755`、普通文件设为 `0644`、shell 入口设为 `0755`，paseo 用户可读取 Relay helper。部署入口的保存包检查同时要求 root 所有、规定权限且无符号链接。
- `00-firewall-relay-check.sh` 在隔离副本中用 nft、DNS 和 HTTPS 命令 stub 验证；HTTP 404 被正确视为 TLS/HTTPS 可达，脚本没有写入 nft 规则。
- Relay helper 使用隔离模块 stub 验证 TLS/E2EE 状态请求成功路径和 `ECONNREFUSED` 诊断；失败输出包含阶段与错误码，不包含模拟的敏感错误文本。此项只验证 helper 的流程和脱敏，不代表真实 Relay 握手通过。
- 当前 Paseo 客户端包的 `DaemonClient`、Relay URL builder 和 `ws` 导出可实际加载，TLS URL builder 输出 `wss://`。
- 从更新脚本提取回滚函数，在隔离目录模拟组件切换及 Codex 旧 release 被移除，确认 Node、Paseo 文件、uv、安装记录、Codex 链接和原先运行的服务状态均恢复。
- 从更新脚本提取服务验收分支，以 systemd、curl 和 Relay 命令 stub 验证：更新前运行的服务会启动并执行本机 health 与 Relay 检查；更新前停止的服务保持停止，跳过这两项网络/服务验收。
- 更新器使用 systemd 与 Codex 命令 stub 验证事务顺序：停服失败或停后仍 active 时不调用 Codex 安装器、不执行更新回滚；停服成功并确认 inactive 后才开始 Codex 安装事务；事务开始后的 Codex 失败会进入回滚分支。
- 工具包内容没有 Docker 安装或运行命令，也不添加工具包自有 checksum 文件或 `sha256sum` 比对。

## A3 本次复验

- A3 全部 Bash 脚本通过 `bash -n`；Python AST、JSON、TOML 和 Relay JavaScript 语法检查通过。
- 当前 Paseo 0.13.0 成功解析基础配置及生成的主 API、BackAPI 配置；Codex 配置 TOML 与 provider 模型内容检查通过。
- 对 A3 更新器实际停服门禁代码使用 systemd/Codex stub 验证：stop 失败或服务仍 active 时不调用 Codex、也不回滚；停服成功后才调用 Codex；Codex 失败会进入回滚。
- 检查确认内部身份为 `paseo-debian`、manifest 固定为 `1.0.0`、systemd 描述和更新锁名不含发布后缀；A3 标识只出现在 README、验证记录和引导入口。
- 安装、强制安装、卸载帮助入口正常；目录 `0755`、Shell 文件 `0755`、其他文件 `0644`，无符号链接/特殊文件、Docker 命令或工具包 checksum 文件。
- 从干净 commit 的 tar 导出构建 ZIP；`unzip -t`、单一顶层目录、文件内容和 ZIP 内 Unix 权限位检查通过。

## 未在此环境验证

没有在真实 Debian VPS 上执行完整 apt 安装、systemd 服务重启、Paseo health 检查或真实 Relay TLS/E2EE 配对。当前执行环境对 A3 unit 运行 `systemd-analyze verify` 返回 `Failed to setup working directory: Read-only file system`，所以 unit 未能由该工具在此处确认。Relay stub 测试不能替代真实网络握手；上线后的配对仍须通过 `03-pair.sh` 验收。

真实部署后可在 VPS 上运行：

```bash
systemd-analyze verify /etc/systemd/system/paseo.service
systemctl --no-pager --full status paseo
ss -lntp 'sport = :6767'
curl --noproxy '*' -fsS http://127.0.0.1:6767/api/health
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261026A3/03-pair.sh
```
