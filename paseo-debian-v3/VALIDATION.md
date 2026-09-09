# v3 检查记录

检查日期：2026-09-09。以下是本地静态/隔离验证，不是用户新 VPS 的安装结果。

## 已检查

- `00-firewall-relay-check.sh`、`01-install.sh`、`02-configure.sh`、`03-pair.sh`、`04-check.sh`、`05-update-tools.sh` 和 `lib/common.sh` 全部通过 `bash -n`。
- `lib/local-check.py` 通过 Python 编译检查。
- README 中的 Bash 示例通过 `bash -n`；PowerShell/TOML/文本示例不按 Bash 解析。
- `templates/codex-config.toml` 通过 TOML 解析；指定的 `gpt-6-astra`、HahaAPI Responses provider、`high`、`never`、`workspace-write` 和 writable roots 均存在。
- 使用 Codex 0.153.4 发布的配置 schema 检查模板通过。
- 使用 Paseo 0.7.2 发布包内的配置 schema 检查模板通过；Relay TLS、Codex 模型目录、禁用语音配置和 worktree 根目录字段通过。
- `apps/package-lock.json` 通过隔离目录的真实 `npm ci --omit=dev`（含生命周期脚本），不依赖系统 npm 全局路径。
- Node.js 22.23.2 amd64 压缩包与 Node 官方 `SHASUMS256.txt` 匹配；部署脚本会按实际 amd64/arm64 架构复验。
- 你指定的防火墙脚本按当前主分支内容核对：普通 Apply 管理 `inet filter`，生成 output accept 和 loopback/已建立连接规则；v3 脚本没有对该脚本、端口列表或 nft managed table 的写操作。
- v3 脚本中没有 `nft add`、`nft insert`、`nft delete`、`nft flush`、`nft replace`、`nft -f` 等防火墙修改操作；`00-firewall-relay-check.sh` 仅查看/测试。
- `03-pair.sh` 在目标用户的交互 shell 中读取 `PASEO_PASSWORD`，避免本机 daemon 已启用密码后无法读取 pairing offer；API key 不会放入命令行参数。
- API key 辅助逻辑用假值验证了不回显、换行/空白/引号拒绝、0600 权限和已有文件不覆盖；未使用真实 key。
- systemd 模板使用固定 Node/CLI 绝对路径、普通 `paseo` 用户、`NoNewPrivileges`、`ProtectSystem=strict` 和 `/srv/paseo` 写入白名单；临时替换为存在的命令/环境文件后通过 `systemd-analyze verify`；`AGENTS.md` 安装在 `/srv/paseo/AGENTS.md` 作为项目父目录约定。
- `relay-check.mjs` 使用固定版本的官方 Paseo client 执行 TLS/E2EE Relay 状态 RPC，且不会打印配对链接、server ID 或密钥。
- `03-pair.sh`、`04-check.sh` 的 Relay 探针路径、服务密码读取路径和失败返回均通过静态检查。
- `05-update-tools.sh` 的 Current/LTS/单项参数、Node 官方 SHA256 校验、npm/uv 更新路径和服务 health 等待逻辑通过静态检查。
- 终端 bracketed-paste 标记说明已加入 README，避免将 `[200~`/`~` 误判为部署错误。
- v3 重复执行检查：预先存在 `/srv/paseo/.profile`、API key、Paseo password hash 和已有配置时，`02-configure.sh` mock rerun 会保留这些内容并继续服务验收；不再把 `.profile` 当成错误。
- ZIP 完整性和包内 `SHA256SUMS` 检查通过。

- 本地完整安装包检查通过：Bash/Python/Node/README 代码块语法、Paseo 0.7.2 配置 schema、Codex 0.153.4 schema、systemd 模板验证、固定包版本运行和 npm lifecycle 安装。

## 未在本地模拟的边界

- 官方 Relay 的真实出站控制连接和客户端配对；必须在用户 VPS 运行 `03-pair.sh`、完成客户端配对并由 `04-check.sh` 验收。
- 第三方 `gpt-6-astra` 的真实 Responses API、工具调用、计费和供应商错误兼容性；必须运行 README 中的 smoke 命令。
- Debian systemd、云厂商出站策略、真实防火墙 Apply 后的连接保持、VPS 重启恢复。
- 手机/Windows Paseo 的具体 UI 版本字段；连接标签可能随客户端版本变化，配对二维码/链接是当前 Relay 流程的稳定入口。

不要把“本地 schema/语法通过”报告为“真实 VPS 已部署”。
