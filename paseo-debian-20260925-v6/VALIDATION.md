# 交付验证记录

对象：`paseo-debian-20260925-v6/`、同名 ZIP 和包内 GitHub `install.sh`。依赖版本沿用 2026-09-25 的固定版本锁。

## 版本与依赖

- Node.js 26.10.0 / npm 11.19.1、`@getpaseo/cli@0.9.2`、`@openai/codex@0.157.0`、uv 0.12.19 保持不变。
- npm manifest 和 lockfile 根包版本为 `2026.9.25-v6`；安装记录和验收核对 `paseo-debian-20260925-v6`。
- v6 不包含安装验收后的缓存清理功能；运行时需要的 cache 环境变量和目录仍保留。

## 本次本地验证

- 包内 `install.sh` 和 v6 全部 shell 脚本通过 `bash -n`；脚本中的 Python heredoc 与 `lib/local-check.py` 可编译。
- Paseo JSON 模板、npm manifest/lockfile 可解析，Codex TOML 可解析；manifest 与 lockfile 的根版本、依赖一致，第三方依赖图未改变。
- 用本地构造的 GitHub 源码归档验证了 v6 目录的唯一发现、解包、`SHA256SUMS` 校验和关键文件检查；下载失败、缺少 v6 目录、校验失败均在安装阶段前停止。
- 入口 `install.sh --help` 和非法参数检查通过；`--force` 由 GitHub 入口转发给 `01-install.sh`，可用于已有托管运行时的远程强制重建。
- `03-pair.sh` 保留配对前后 health/Relay 检查，不调用缓存清理或因清理重启服务。
- `SHA256SUMS` 中全部文件校验通过；同名 ZIP 通过 `unzip -t`，未包含 Git 元数据或依赖安装目录。

Node.js/npm 不在本地验证环境中，因此没有执行 `npm ci` 或 `npm audit`；依赖和 lockfile 中的第三方解析结果未更改。未在 VPS 上执行真实安装、systemd 启动、客户端扫码或真实 API 请求。

## 目标主机验证

- 在 Debian 12/13 的干净主机上，以交互式 root SSH 终端运行 README 中的 curl 命令。
- 完成 API 配置、Paseo 管理密码和客户端配对；最终应输出 `STEP1_OK`、`STEP2_OK` 和 `CHECK_OK`。
- 真实 API smoke test 会消耗 provider 额度，应从客户端发起小任务验证。
