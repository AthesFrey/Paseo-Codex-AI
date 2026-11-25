# V12 验证记录

核验日期：2026-11-25。官方版本元数据在该日期查询；安装器运行时仍从官方源解析最新稳定版。

## 官方版本快照

- Node.js LTS `26.13.1`（Node.js 官方索引）；该归档自带 npm `11.20.0`。
- npm `12.2.3`（npm registry latest）。
- Paseo CLI `0.17.4`（npm registry latest）。
- Codex CLI `0.172.0`（OpenAI 官方安装器对应 `rust-v0.172.0`）。
- Claude Code `2.1.332`（Anthropic 官方 latest）。
- uv `0.13.10`（Astral uv GitHub latest；安装使用 Astral 官方安装器）。

## 已执行检查

- 所有 shell 脚本通过 `bash -n`；Relay JavaScript 通过 `node --check`；Python 文件通过 AST 解析；JSON 和 TOML 模板解析通过。
- Relay 诊断测试 3 项通过，覆盖 DNS/TCP/TLS/HTTP 故障分类、错误链和 URL/token 脱敏。
- Python 测试运行 10 项：8 项通过，2 项因没有显式提供当前官方 CLI 路径而跳过；覆盖配置生成、密钥权限、环境过滤和部署流程边界。Claude 路径链接测试脚本另行通过。
- Paseo 当前官方 CLI `0.17.4` 发布包静态检查确认 `daemon config get`、`daemon run`、`daemon pair --relay` 接口存在；公开 v1 schema 和 `@getpaseo/server` 配置解析源码包含模板使用的 Relay、worktree、provider、model 和 feature 字段。
- 安装入口帮助输出、`--force` 参数入口、V12 发布标识、systemd 模板路径和原生 systemd 启动命令检查通过。APT 依赖和服务模板没有 Docker 依赖。
- 官方版本查询结果及 V12 安装器入口均在验证时确认。

## 未执行检查

- 自动审查阻止在隔离缓存中安装并执行当前 Paseo/Codex npm/standalone 二进制；因此没有声称当前 CLI/Codex 实际解析测试通过。公开包接口、schema 与配置解析源码只做了静态核对。
- `systemd-analyze verify` 在当前受限执行环境无法建立工作目录（文件系统只读）；systemd unit 做了静态字段和路径检查。
- 未在真实 Debian VPS 执行完整安装、更新/回滚、启动服务、Relay E2EE 配对或模型 API 请求。
