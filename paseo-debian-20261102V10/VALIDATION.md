# V10 验证记录

核验日期：2026-11-02。检查在隔离目录中完成，没有使用真实 API key、访问模型中转 API、启动 VPS 服务或操作 systemd。

## 验证结果

- `tests/test_provider_config.py` 的 7 项测试通过：HTTPS 校验和 Codex/Claude URL 规范化；模型列表顺序、去重、空输入和默认模型；生成配置仅含手选模型；Codex 主配置及环境过滤；Claude 命令桩的 key/base URL 环境；密钥输入不回显及 `0600` 文件权限。
- 密钥写入测试在临时目录执行，验证了源函数要求 `root:root` 的代码路径、权限位和不回显行为。测试进程没有 root 权限时，仅在提取出的临时函数中把 `chown` 调用换成当前测试用户；`local-check.py` 仍会在实际部署中校验 secret 为 `root:root 0600`。
- 当前 Codex standalone 以 `--strict-config` 解析生成的主 API 配置；当前 Paseo CLI 成功解析生成的 provider 配置。
- Claude 调用地址核对了 `@anthropic-ai/sdk` 1.3.0 的请求实现：消息路径为 `/v1/messages`。因此工具接受根地址或以 `/v1` 结尾的输入，但生成的 `ANTHROPIC_BASE_URL` 去掉 `/v1`，避免重复路径。
- 所有 shell 脚本通过 `bash -n`；Python 源码通过 AST 解析；JSON/TOML 模板通过解析；Relay JavaScript 通过 `node --check`；`install.sh --help` 显示 V10 下载路径；`git diff --check` 通过。
- Anthropic 官方安装器在隔离 HOME 中以 `latest` 通道安装成功，报告版本为 Claude Code 2.1.316；服务 PATH 和安装状态检查均指向工具管理的 Claude Code 命令路径。

## 未执行项目

- 未使用真实 API key 向 Claude 中转或主 API 发起请求。
- 未在全新 VPS 上运行完整安装、systemd 服务启动、Relay 配对或真实客户端聊天。
