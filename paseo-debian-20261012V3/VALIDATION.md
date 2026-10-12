# paseo-debian-20261012V3 交付验证记录

对象：`paseo-debian-20261012V3/` 及同名 ZIP。版本策略是安装时解析 Node.js 最新正式 LTS、npm latest、Paseo CLI latest、OpenAI Codex standalone latest 和 uv 最新正式 release。

## 已执行验证

- 所有 shell 脚本通过 `bash -n`；Python 源码通过 AST 编译检查；Relay JavaScript 通过 Node 语法检查。
- 所有 JSON/TOML 模板和 `apps/package.json` 可解析；manifest 版本为 `2026.10.12-v3`，只声明 `@getpaseo/cli: latest`。
- 入口 stdin、stdin 参数和本地路径三种调用形态都不会读取未定义的 `BASH_SOURCE[0]`。
- Node.js 官方 index 选择逻辑只接受最新正式 LTS（安全发行版也保留）；归档使用官方 `SHASUMS256.txt` 校验，并检查 npm `engines.node`。本次官方响应观测为 Node.js LTS `24.21.0`、npm `12.2.0`。
- 在隔离缓存中从 registry 安装 `@getpaseo/cli@latest`，解析到 Paseo `0.11.2`；动态 package-lock integrity 有效，`esbuild@0.25.12`、`msgpackr-extract@3.0.4`、`node-pty@1.2.0-beta.15` 完成 native/install-script rebuild，Node 加载测试通过，临时 `.npmrc` 已删除。
- Codex 安装器只接受包含 OpenAI 官方 release 地址的当前脚本；安装布局、管理链接、版本和帮助命令由安装脚本及目标主机验收脚本检查。
- uv 使用 GitHub 正式 release 的官方 `sha256.sum`，按架构选择归档并校验 `uv`/`uvx`。
- 配置写入测试覆盖主 API、BackAPI、默认模型、五档 thinking options、Codex TOML、Paseo v1 config 和秘密文件权限。
- paseo-debian-20261012V3 安装模板默认开启 dictation、关闭 voice mode；Paseo 0.11.2 schema 接受该配置。默认本地 STT 模型仅面向英语，中文 STT 需独立配置兼容服务。
- 静态检查确认不安装、不调用 Docker，也不把 Docker 作为 systemd 或运行时依赖。
- 新包逐文件 SHA256、ZIP 完整性、唯一顶层目录和归档后重新校验均通过；更新脚本还检查锁文件、托管目录属主/权限、秘密文件、Codex standalone 目标和受保护配置内容。

## 目标主机验证

当前执行环境不是 root Debian VPS，且 systemd 工作目录受沙箱只读限制，因此没有把真实 apt 安装、systemd 服务重启、Relay 配对或模型请求计为通过；`systemd-analyze verify` 需在目标 VPS 的实际路径上执行。部署后应在 root SSH 终端依次确认：

```bash
systemctl --no-pager --full status paseo
systemd-analyze verify /etc/systemd/system/paseo.service
ss -lntp 'sport = :6767'
curl --noproxy '*' -fsS http://127.0.0.1:6767/api/health
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261012V3/03-pair.sh
```

真实 API key 不用于本地构建或验证；诊断输出不得包含 key、密码或配对链接。
