# V11 验证记录

核验日期：2026-11-02。自动化检查使用隔离临时目录，没有使用真实 API key，也没有操作 VPS 服务或 systemd。

## 验证结果

- `tests/test_claude_path_links.py` 通过：模拟 Anthropic 命令链接到版本目录的布局，验证管理链接直接目标、`--version` 执行，以及安装、更新和卸载脚本使用直接链接判断。
- `tests/test_provider_config.py` 的 7 项测试通过：HTTPS 校验和 URL 规范化、模型选择、生成配置、Codex 环境过滤、Claude 命令环境以及 secret 文件权限。
- 所有 shell 脚本通过 `bash -n`；5 个 Python 源码文件通过 AST 解析；JSON/TOML 模板解析成功；Relay JavaScript 通过 `node --check`。
- `install.sh --help` 显示 V11 下载路径。

## 未执行项目

- 未在 Debian VPS 上运行完整安装或更新，也未启动 systemd 服务、执行 Relay 配对或发起真实 API 请求。
