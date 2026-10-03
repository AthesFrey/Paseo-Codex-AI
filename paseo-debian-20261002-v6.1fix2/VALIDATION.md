# v6.1fix2 交付验证记录

对象：`paseo-debian-20261002-v6.1fix2/` 及同名 ZIP。此版本移除部署阶段的模型目录网络请求，改为手动输入模型 ID；版本标识为 `v6.1fix2`。

## 已执行验证

- 所有 shell 脚本通过 `bash -n`；Python 源码通过内存 AST 编译检查，未在项目目录生成字节码。
- `apps/package.json`、Paseo JSON 模板和 Codex TOML 模板可解析；包版本为 `2026.10.2-v6.1fix2`。
- 手动模型输入单元测试覆盖逗号分隔、空白分隔、首个模型默认、空输入、重复 ID、控制字符和终端 EOF。
- 隔离 PTY 测试确认示例 `gpt-6.1-sol,gpt-6-sol,gpt-6-astra` 直接生成 ID 选择 JSON，首个 ID 为默认模型。
- 静态检查确认模型输入模块和配置脚本不包含模型目录请求、Bearer 查询、curl 子进程或旧编号选择参数。
- 在 `/srv/paseo/cache/paseo_ai/v6.1fix2-validation/` 隔离目录生成主 API 和 BackAPI 配置，检查模型 ID、各自默认模型、Codex TOML、metadata generation 及五档难度设置。
- 使用当前已安装 Paseo CLI 对隔离生成的 Paseo v1 配置执行 `paseo daemon config get`，解析通过。
- 发布目录逐文件 SHA256 校验、ZIP 完整性、唯一顶层目录和归档内容检查均通过。

## 未执行的目标主机检查

未在目标 Debian 主机执行 apt 安装、systemd 服务重启、Relay 配对或真实模型请求；这些需要在新机器部署后验证。API key 未用于本地真实请求。
