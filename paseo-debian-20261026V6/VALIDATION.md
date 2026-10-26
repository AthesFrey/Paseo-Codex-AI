# V6 验证记录

核验日期：2026-10-26。以下结果来自本次可用的 Debian/Linux 构建环境；没有在全新 VPS 上执行真实安装。

## 通过项目

- 所有 shell 脚本通过 `bash -n`。
- Python 文件通过 AST 解析；JavaScript 通过 `node --check`；JSON 和 TOML 模板均可解析。
- 安装运行时版本与官方当前元数据一致：Node.js 最新 LTS `24.22.1`、npm registry latest `12.2.1`、Paseo CLI latest `0.13.0`。官方安装器当前解析到 Codex standalone `0.164.0` 和 uv `0.13.5`。
- 在 `/srv/paseo/cache` 的一次性目录中从 npm 官方 registry 全新安装 Paseo CLI latest；安装器审批 `esbuild`、`msgpackr-extract`、`node-pty` 的待执行脚本并成功 rebuild。CLI 为 `0.13.0`，573 个依赖包均存在，`npm ls --all` 未发现缺失或无效依赖。
- 使用当前 Paseo CLI 解析生成配置通过；主 API 与 BackAPI 多模型配置均以 `gpt-6-astra` 为默认模型。
- Relay 检查器从隔离布局中的 `PASEO_RUNTIME_ROOT/apps/node_modules` 解析 CLI、client、protocol 和 WebSocket 依赖，并进入 Relay 连接阶段。故意缺失 runtime 与配置时，分别得到依赖加载和配置读取阶段的 `ENOENT` 提示。
- 从 stdin 启动安装入口的帮助模式通过。卸载器在隔离命令桩下通过 stdin 执行 `--dry-run` 与未完成安装的 `--yes` 路径；服务停止失败时，脚本在任何删除命令前退出。
- 静态复核确认安装步骤顺序为 `00`、`01`、`02`、`03`，`--force` 传给 `01-install.sh`；更新事务包含运行时、Codex 选择和服务状态回滚。

## 未执行项目

- Relay TLS/E2EE 连接尝试未完成；依赖加载和配置读取均已通过，剩余失败位于外部 Relay 连接阶段。未验证真实 VPS 的 Relay 往返或客户端配对。
- 未在 Debian 全新机器执行完整安装、强制覆盖、systemd 启动或在线更新。当前容器的 `systemd-analyze verify` 无法完成，因为容器文件系统对该检查所需路径只读。
- 没有在全新 Debian 主机上重新安装 Node.js、Codex standalone 和 uv；这些组件仅在当前环境按官方索引或安装器结果核验。

发布 ZIP 的提交来源、可复现构建比较和 SHA-256 在提交后单独核验并随交付结果记录。
