# V9 验证记录

核验日期：2026-11-02。验证使用隔离临时目录、Codex standalone 0.166.0、Paseo CLI 0.14.0 和命令桩；没有调用真实 BackAPI，也没有操作 VPS 服务或 systemd。

## 验证结果

- `tests/test-backapi-config.py` 的 6 项测试通过：主 API 配置保持不变；备用 provider 与 `codex-bk` profile 匹配；裸 HTTPS 地址补全 `/v1`、HTTP 被拒绝；跳过 BackAPI 时移除 profile/provider；wrapper 使用 `--profile backapi` 并传递 API key；配置和输出均不包含测试 key。
- 当前 Codex standalone 以 `--strict-config` 解析生成的 profile，`app-server --help` 通过。
- 当前 Paseo CLI 成功解析生成的 provider 配置。
- 所有 shell 脚本通过 `bash -n`；所有 Python 源码通过 AST 解析；JSON/TOML 模板通过解析；Relay JavaScript 通过 `node --check`；`git diff --check` 通过。
- 安装入口 `install.sh --help` 显示 V9 下载路径。

## 未执行项目

- 未使用真实 API key 向 `https://sub2.hahaapi.com` 发起请求。
- 未在全新 VPS 上运行完整安装、systemd 服务启动、Relay 配对或真实客户端聊天。
