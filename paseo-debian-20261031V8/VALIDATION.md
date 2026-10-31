# V8 验证记录

核验日期：2026-10-31。测试环境为 Debian 13 (trixie)、ARM64。安装和部署脚本在 `/srv/paseo/cache` 下的隔离副本及命令桩中测试；没有修改真实 `/srv/paseo`、`/srv/proj`、`/etc` 或运行真实 systemd 服务。

## 验证结果

- 从 Node.js 官方索引解析并校验 `26.13.0` LTS 归档 SHA-256；从 npm registry 安装 `12.2.1`，从 registry 安装 Paseo CLI `0.14.0`，并通过 Astral 安装器安装 uv `0.13.6`。OpenAI Codex standalone 安装器解析到 `0.166.0`。安装器在实际部署时动态解析官方当前版本；这些数字仅记录本次观察结果。
- 当前 Paseo 运行依赖树包含 345 个 lockfile 包；`npm ls --all` 未报告缺失或无效的必需依赖。未安装或引用 `@openai/codex` npm 包。
- `01-install.sh` 在隔离路径中完成新装和 `--force` 重装；组件版本、运行路径和权限检查通过。非强制覆盖保护和模拟 systemd 停服失败场景通过，停服失败时没有替换现有运行时。`install.sh --help` 和模拟停服失败的卸载保护通过。
- 当前 Paseo CLI 成功解析生成的配置；使用当前 Codex standalone 验证了 `--strict-config --help` 和 `app-server --help`。
- Relay 检查器使用当前 `daemon-control.waitForDaemonReady` API。隔离测试让 daemon 锁延迟出现，检查器等待后进入本机拒绝端口的 Relay 阶段；活动监听地址不匹配时在 Relay 网络访问前返回 `LOCAL_DAEMON_IDENTITY_MISMATCH`。
- 在临时运行时文件和 fake `systemctl` 状态机中强制触发更新失败退出路径；回滚处理器恢复了旧运行时文件、安装记录、Codex release/link 和 auto-update 值，也恢复先前 active 的服务状态并清理 staging。
- 所有 shell 脚本通过 `bash -n`；3 个 Python 文件通过 AST 解析；Relay JavaScript 通过 `node --check`；所有 JSON 和 TOML 文件均可解析；`git diff --check` 通过。工具包目录为 `0755`，shell 文件为 `0755`，其他普通文件为 `0644`。
- `systemd-analyze verify` 尝试验证 unit 模板时因容器无法设置可写工作目录而退出：`Failed to setup working directory: Read-only file system`。模板路径、EnvironmentFile、用户、工作目录和 ExecStart 已静态检查；没有声称该命令通过。
- 工具包使用原生 systemd，不安装或调用 Docker；部署脚本和 systemd 模板未发现 Docker 运行依赖。

## 未执行项目

- 没有可用的真实 Paseo Relay，因此未完成 TLS/E2EE Relay 往返、真实状态 RPC 或客户端配对。延迟 daemon 测试只验证本机就绪等待和拒绝地址保护。
- 未对真实 systemd 执行安装、服务启动、更新或卸载，也未完成 systemd unit 的运行时验证。未在独立全新 VPS 上从 `00` 到 `03` 完成带交互输入的端到端部署。
- 没有把 Relay 检查器的真实 E2EE/RPC 失败直接注入完整更新进程；上面的失败注入验证了更新器公共失败退出路径和回滚处理器，但不替代真实 Relay 故障测试。

OpenAI Docs 的 Codex CLI 安装说明确认 macOS/Linux standalone 安装方式；工具包使用其官方安装入口 `https://chatgpt.com/codex/install.sh`：<https://developers.openai.com/codex/cli/>。

提交 SHA、ZIP checksum、构建来源、归档完整性、权限检查和两次构建结果在交付时记录。
