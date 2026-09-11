# v3.2 验证记录

检查日期：2026-09-10。基线为本次上传的 `paseo-debian-v3.zip`。以下区分真实程序运行、隔离模拟和未完成的外部验收。

## 已完成

- 全部部署脚本和 `lib/common.sh` 通过 `bash -n` 与 ShellCheck；README 中的 Bash 示例通过语法检查。
- 内嵌 Python、`lib/local-check.py` 和 `lib/relay-check.mjs` 通过语法检查；JSON/TOML 模板均可解析。
- Paseo 0.7.2 发布包中的实际 `PersistedConfigSchema` 接受配置模板，包括五档思考深度和 High 默认值。
- Codex 0.153.4 以 `app-server --strict-config` 实际读取配置，确认 HahaAPI、`gpt-6-astra`、High 和 `workspace-write` 生效。
- 使用真实 Codex app-server 向本机模拟 Responses 服务发送五次请求并完成响应，逐次确认 `reasoning.effort` 为 `low`、`medium`、`high`、`xhigh`、`max`。只使用假 key，没有调用 HahaAPI。
- 包内 lockfile 在独立目录完成真实 `npm ci --omit=dev --no-audit --no-fund`，包含生命周期脚本；Paseo 0.7.2 和 Codex 0.153.4 可运行。依赖图与附件 v3 一致，仅部署包元信息更新为 3.2.0。
- Node.js 22.23.2 官方 amd64 压缩包下载、SHA256 校验、解压和版本运行通过。实际发现 `mktemp` 的 0700 目录权限会随目录移动保留；安装及升级脚本均已添加 `chmod 0755`。
- 使用刚安装的真实 Paseo 0.7.2 在隔离目录以前台方式启动，回环 health 成功；真实 CLI 的 `provider models codex --thinking` 查询返回指定模型及全部五档选项。该测试关闭 Relay，使用独立状态目录和随机本机端口，结束后停止进程。
- systemd 模板的程序路径、工作目录、环境文件、读写目录和只读程序目录进行了静态核对；真实 CLI 接受模板中的启动选项。

## 部署脚本隔离模拟

复制部署脚本到独立测试目录，重定向部署路径，以替身代替 apt、用户管理、systemctl、下载、npm/uv 和交互输入；没有在当前主机执行 root 安装或修改系统服务。

已通过的场景：

- 首次安装创建 `/srv/proj`，项目目录为 0700，Node 目录为 0755，程序集中于 `/srv/paseo/runtime`，不创建旧项目目录。
- 首次配置直接安装五档思考选项、全局 `AGENTS.md`、0600 密钥文件，并进入服务启动/检查流程。
- 重复执行保留 API key、密码哈希、用户自定义默认档位、Codex 配置和 `.profile`；已安装且 lockfile 未变化的 npm 依赖不会重装。
- Node LTS 更新可在没有全局 Node 的 PATH 下调用自带 Node/npm，重建依赖、恢复服务并清理临时文件。
- CLI 单项更新只执行一次 npm install；不再额外重复执行 npm ci。
- Node SHA256 不匹配时返回失败，保留原 Node、恢复之前运行的服务并清理下载文件。
- 升级前停止的服务保持停止；帮助和无效参数处理正常。
- 假 API key 未出现在脚本输出中。

检查工具的隔离回归验证：

- 本机检查通过正常配置，拒绝错误工作目录、项目目录不可写、公网监听、密钥文件权限错误、缺少密码和关闭 Relay TLS 六类错误。
- Relay 探针使用模拟安装版本 9.9.9 正常通过，证明不再写死 0.7.2；连接到错误 daemon 时失败，输出不包含 daemon 标识或密钥。

## 打包核对

- 新包无 backapi 脚本/配置、旧 `/srv/paseo/projects` 项目路径或 `/opt/paseo-v3` 程序路径。
- 清除旧版本的动态 latest 断言和过期检查记录；保留固定依赖和有用的维护脚本。
- 包中只包含交付脚本、模板、文档、依赖清单及 `SHA256SUMS`，不包含 node_modules、测试状态、缓存、日志或凭据。
- ZIP 解压完整性、逐文件 SHA256 和发布版本检查通过。

## 仍需在新 VPS 验收

- 当前环境中的 `systemd-analyze verify` 无法运行，返回 `Failed to setup working directory: Read-only file system`，因此不计为通过。实际 systemd 启动、服务文件系统保护、重启恢复需要在新 VPS 检查。
- 没有连接用户的真实 HahaAPI、官方 Relay 或手机/Windows 客户端；本机模拟接口测试不代表供应商实际接受所有档位。按 README 运行 `03-pair.sh`、`04-check.sh` 和 API smoke 完成端到端验收。
- 没有启动 Debian 12/13 全新虚拟机进行 apt 安装，也未运行 arm64 二进制。安装脚本保留原包的双架构选择和下载校验流程。
