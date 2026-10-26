# V7 验证记录

核验日期：2026-10-26。检查在隔离的 Debian/Linux 环境中完成；没有对真实 `/srv/paseo`、`/etc`、systemd 或 Relay 服务执行操作。

## 通过项目

- 所有 shell 脚本通过 `bash -n`；3 个 Python 文件通过 AST 解析；Relay JavaScript 通过 `node --check`；2 个 JSON 文件和 1 个 TOML 文件均可解析。
- 在 `/srv/paseo/cache` 隔离目录中从 npm 官方 registry 安装 Paseo CLI `latest`。registry 解析结果为 `0.13.1`，Node.js/npm 测试环境分别为 `24.22.1` 和 `12.2.1`。完整依赖树有 573 个依赖节点，`npm ls --all` 没有缺失或无效依赖。
- npm 12 阻止的 `esbuild`、`msgpackr-extract`、`node-pty` install scripts 经临时 allowScripts 配置批准；`npm rebuild` 成功，临时 `.npmrc` 已移除。
- 当前 Paseo CLI 成功解析 `templates/paseo-config.json`。
- 使用当前 CLI 的 `daemon-control` API 和隔离 home 验证：活动 PID 锁、匹配监听地址及凭据通过本机预检并进入 Relay 连接阶段；新凭据轮换后再次检查仍能通过预检；监听地址不匹配和凭据缺失返回 `LOCAL_CREDENTIAL_UNAVAILABLE`；失效 PID 锁返回 `LOCAL_DAEMON_NOT_READY`。连接目标仅为本机拒绝端口 `127.0.0.1:1`。
- 使用当前 `DaemonClient` 和 loopback WebSocket 验证 hello 消息包含 `kind: localCredential`，不包含配置中的密码。
- 安装入口帮助模式可从 stdin 运行；卸载器在隔离命令桩下通过 stdin 执行 `--dry-run` 和未完成安装的 `--yes` 路径。模拟服务停止失败时，脚本在执行删除命令前退出。
- 静态复核确认安装顺序为 `00`、`01`、`02`、`03`，`--force` 传给 `01-install.sh`；更新流程在替换前暂存运行时、Codex 选择和服务状态，失败时执行回滚。

## 上游审计

- `npm audit` 对 Paseo CLI `0.13.1` 依赖树报告 9 项公告：3 项 low、1 项 moderate、5 项 high、0 项 critical，涉及 `@getpaseo/server`、MCP SDK、`markdown-it`/`linkify-it`、`uuid` 及其依赖。npm 给出的自动修复需要降级 CLI 到 `0.4.0`；本包按要求安装官方当前 latest，没有应用该降级或覆盖 Paseo 依赖。

## 未执行项目

- 未完成真实 Relay TLS/E2EE 往返或客户端配对。loopback client 测试只核验认证消息生成；隔离检查器的有效凭据场景在本机拒绝端口结束。
- 未在全新 Debian VPS 执行完整安装、`--force`、systemd 启动或在线更新。当前容器的 `systemd-analyze verify` 因检查路径只读而未能完成。
- 未在本次验证中重新安装 Codex standalone 或 uv；安装器相关流程未改动。

提交 SHA、构建来源、ZIP checksum、双次构建比较和归档权限检查在提交后记录于交付结果。
