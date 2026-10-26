# paseo-debian-20261026V5 验证记录

验证日期：2026-10-26。执行环境为 Debian 13 (trixie)、x86_64。以下动态安装均写入 `/srv/paseo/cache/debianvps/` 下的隔离目录；未在真实 `/srv/paseo`、`/etc` 或 systemd 安装服务。

## 已执行

- 从 Node.js 官方索引解析到最新 LTS `24.22.1`，在隔离目录安装官方 Linux x64 归档；从 npm 官方 registry 解析并安装 `npm 12.2.1`。npm 声明的 Node.js 范围为 `^22.22.2 || ^24.15.0 || >=26.0.0`，包含该 Node.js 版本。
- 从 npm 官方 registry 安装 `@getpaseo/cli@latest`，解析到 `0.13.0`，安装 303 个依赖包。npm 将 `esbuild@0.25.12`、`node-pty@1.2.0-beta.15` 和 `msgpackr-extract@3.0.4` 的安装脚本列为待审批；按安装器流程临时允许并 rebuild 成功，临时 `.npmrc` 已删除。依赖树包含 `uuid@9.0.1` 的弃用提示，未阻止安装或构建。
- 使用当前 OpenAI 官方 standalone 安装器在隔离目录安装 Codex `0.164.0`；版本、`--strict-config --help` 和 `app-server --help` 检查通过。受限环境中的安装器无法创建 PATH alias，但指定安装目录内的 Codex 命令可正常运行。使用 Astral 官方安装器安装并验证 uv `0.13.5`。
- Paseo CLI 成功解析基础模板及生成的主 API/BackAPI 配置；Codex TOML 和 Paseo JSON 可解析。
- V5 全部 Bash 脚本通过 `bash -n`；Python 文件通过 AST 解析；Relay JavaScript 通过 `node --check`；JSON/TOML 解析通过。
- 在隔离副本用 cURL、apt 和步骤命令 stub 模拟管道启动器：归档定位、Step 1 后保存 V5 工具包、`--force` 参数转发及 `00`、`01`、`02`、`03` 顺序均通过。
- 在重定向到隔离目录的副本中通过 stdin 测试卸载器：部分安装且没有保存工具包时，`--dry-run` 不修改状态，`--yes` 在服务停止后清理托管运行时；停服失败或服务仍 active 时保留文件。测试确认项目、worktrees、缓存、其他工具、其他 systemd drop-in 保留，非托管 Codex 文件不会被删除。
- `01-install.sh` 强制覆盖预检接受指向官方 standalone 的链接，拒绝普通文件及指向非官方位置的 Codex 链接；已有托管路径在未指定 `--force` 时被拒绝。
- 从更新脚本提取当前回滚函数，在隔离目录验证 Node、Paseo、uv、安装记录、Codex release/链接和更新前运行的服务状态恢复。另验证 Codex 更新只在停服成功且服务 inactive 后进入事务。
- 静态检查确认 manifest 内部版本为 `1.0.0`、依赖为 `@getpaseo/cli: latest`；systemd unit 的服务用户、工作目录、环境文件、运行路径和隔离选项与模板一致。运行时环境不包含 API key 值。工具包不安装或运行 Docker；没有添加工具包自有 checksum 清单。
- 文件权限检查要求目录 `0755`、Shell 文件 `0755`、其他文件 `0644`。发布 ZIP 构建后使用 `unzip -t` 验证完整性，并检查唯一顶层目录、文件清单与 Unix 模式位。

## 未在此环境验证

- `systemd-analyze verify` 对原始 unit 及隔离副本均因执行环境只读错误 `Failed to setup working directory: Read-only file system` 未能完成。服务未在真实 VPS 启动；未执行真实 Relay TLS/E2EE 配对。
- 本次在 Debian 13 x86_64 验证了 Linux x64 二进制，未运行 arm64 二进制。

真实 VPS 部署后可执行以下检查：

```bash
systemd-analyze verify /etc/systemd/system/paseo.service
systemctl --no-pager --full status paseo
ss -lntp 'sport = :6767'
curl --noproxy '*' -fsS http://127.0.0.1:6767/api/health
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261026V5/03-pair.sh
```
