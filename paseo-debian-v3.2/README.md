# Paseo Debian 部署包 v3.2

以附件 `paseo-debian-v3.zip` 为基线，面向全新 Debian VPS。沿用 HahaAPI、原生 Codex 和 Paseo Relay，固定依赖版本保持不变。

本版调整：

- 默认项目根目录改为 `/srv/proj`，服务工作目录和 Codex 写入权限同步调整。
- 程序部署在 `/srv/paseo`：Node、Paseo、Codex、uv 和运行库集中于 `/srv/paseo/runtime`。
- `gpt-6-astra` 预置 **Low / Medium / High / Extra High / Max**，默认 **High**，首次配置时直接生效。
- 全局项目约定安装到 `/srv/paseo/.codex/AGENTS.md`，覆盖 `/srv/proj` 和 worktree 中的 Codex 任务。
- 修正 Node 安装目录权限、升级时的 Node 查找路径、重复 npm 安装、临时文件清理和 Relay 检查写死版本的问题。

## 运行方式与目录

```text
手机 / Windows Paseo
  → Paseo Relay（出站 TLS、端到端加密）
  → VPS daemon：127.0.0.1:6767
  → 原生 Codex app-server
  → https://sub2.hahaapi.com/v1（Responses API）
```

| 路径 | 用途 |
|---|---|
| `/srv/proj/<项目名>` | 默认项目位置 |
| `/srv/paseo/runtime` | root 管理的程序和依赖；在服务内只读 |
| `/srv/paseo/worktrees` | Git 工作树 |
| `/srv/paseo/tools` | 项目所需的用户级工具链 |
| `/srv/paseo/cache` | 下载、编译、包管理器和临时缓存 |
| `/srv/paseo/.codex` | Codex 配置和全局项目约定 |
| `/srv/paseo/.paseo` | Paseo 配置、会话和配对状态 |
| `/etc/paseo/runtime.env` | 服务运行环境 |
| `/etc/paseo/hahaapi.env` | API key，root:root、0600 |

服务以普通用户 `paseo` 运行，home 保持 `/srv/paseo`。服务默认工作目录为 `/srv/proj`；未指定位置的新项目按全局约定创建在其子目录中。客户端选择已有工作区或明确指定路径时，任务采用该路径。

程序目录中的依赖由部署脚本维护；项目依赖使用项目自己的 manifest 和 lockfile。Codex 默认允许在项目、worktree、工具和缓存目录中写入及联网，使用 `approval_policy = "never"`、`sandbox_mode = "workspace-write"`。缺少系统开发库时，由管理员按项目需要安装。

## 新 VPS 安装

要求：Debian 12（bookworm）或 Debian 13（trixie），amd64/x86_64 或 arm64/aarch64，systemd、root SSH 终端；建议至少 2 vCPU、2 GiB RAM、8 GiB 可用空间。

将压缩包上传到 `/root`，进入 root 会话后执行：

```bash
apt-get update
apt-get install -y --no-install-recommends unzip ca-certificates curl nftables
cd /root
unzip paseo-debian-v3.2.zip
cd paseo-debian-v3.2
sha256sum -c SHA256SUMS
```

保留完整目录，包括 `apps/`、`lib/` 和 `templates/`。本包不提供旧版迁移脚本。

### 0. 只读检查 Relay 出站网络

```bash
bash 00-firewall-relay-check.sh
```

通过标记：`FIREWALL_RELAY_CHECK_OK`。

需要 DNS 和到 `relay.paseo.sh:443` 的出站连接，以及已建立连接的回包。脚本只查看 nftables 并测试 HTTPS，不修改规则。Relay 不需要新增公网入站端口，**不要开放 TCP 6767**。若出站检查失败，先检查 DNS、云厂商出站策略和主机 output 规则。

### 1. 安装固定版本工具

```bash
bash 01-install.sh
```

| 工具 | 固定版本 |
|---|---|
| Node.js | 22.23.2 |
| Paseo CLI | 0.7.2 |
| Codex CLI | 0.153.4 |
| uv | 0.12.11 |

同时安装 Git、Git LFS、ripgrep、jq、tmux、rsync、Python 3/venv、C/C++ 构建工具、`pkg-config`、OpenSSL/FFI 开发头文件等基础依赖。

Node 下载后校验官方 SHA256；Paseo/Codex 使用包内 lockfile 执行 `npm ci`；uv 装在独立 venv 内。`/srv/proj` 由 `paseo:paseo` 持有，权限为 0700。

通过标记：`STEP1_OK`。中断后可重跑；已有可执行工具和已升级版本会保留，缺失部分会补齐。

### 2. 配置 API、密码和服务

保持 SSH 交互终端：

```bash
bash 02-configure.sh
```

首次运行会依次要求：

1. 输入 `HAHA_API_KEY`，不回显。
2. 设置 Paseo 本机管理密码，输入两次。

API key 用于模型请求；Paseo 密码用于本机 CLI 认证。密码以 bcrypt 哈希保存在 Paseo 配置中。

脚本安装配置模板，启动并启用 `paseo.service`，检查回环监听、health、项目工作目录及关键文件。通过标记：`STEP2_OK`。

默认 Codex 配置使用：

```toml
model = "gpt-6-astra"
model_provider = "hahaapi"
model_reasoning_effort = "high"

[model_providers.hahaapi]
name = "HahaAPI"
base_url = "https://sub2.hahaapi.com/v1"
env_key = "HAHA_API_KEY"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
```

完整权限和环境配置见 `templates/codex-config.toml`。默认关闭本地听写、语音模式和 Web UI，保留 v3 的文字任务流程。

`/srv/paseo/.paseo/config.json` 中的模型目录直接包含五档思考选项：`low`、`medium`、`high`、`xhigh`、`max`，其中仅 `high` 标记为默认。**不需要再执行额外 Python 修改脚本。** 配对后可在客户端选择思考深度；选项由 Paseo 传给 Codex，实际调用能力取决于 HahaAPI 对该模型参数的支持。

重跑本步骤会保留已有 API key、密码、配置和 `.profile`，只补齐缺失文件，并刷新服务单元后重启检查。它不会重置你后来手动设置的默认思考深度。

### 3. 配对手机 / Windows

```bash
bash 03-pair.sh
```

脚本检查本机和真实 TLS/E2EE Relay 往返连接，然后询问 Paseo 本机管理密码，在当前终端显示二维码/配对链接。通过标记：`PAIRING_READY`。

在手机或 Windows Paseo 中添加主机，扫描二维码或粘贴链接。配对链接视同访问凭据，只在自己的客户端使用，不要发布到日志或聊天。

### 4. 检查连接

```bash
bash 04-check.sh
```

应依次看到 `LOCAL_OK`、`RELAY_OK`、`CHECK_OK`。检查包含服务用户、`/srv/proj` 工作目录和写权限、回环监听、health、密码/API key 文件以及 Relay 到当前 daemon 的状态请求。

再从已配对客户端创建一个位于 `/srv/proj` 的项目并发送简单任务，检查返回结果和五档思考选项。CLI 查询模型选项的命令见下面的 smoke 步骤。

## 模型 API 与依赖安装验收

以下命令通过已运行的 daemon 执行一次真实模型任务，会消耗 HahaAPI 额度。API key 从服务配置读取，不放入命令行。使用 root 终端执行：

```bash
runuser -u paseo -- bash <<'SMOKE'
set -Eeuo pipefail
export HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex PASEO_HOME=/srv/paseo/.paseo
export PATH=/srv/paseo/runtime/apps/node_modules/.bin:/srv/paseo/runtime/node/bin:/srv/paseo/runtime/uv/bin:/srv/paseo/tools/bin:/usr/bin:/bin
mkdir -p /srv/proj/v3.2-smoke
cd /srv/proj/v3.2-smoke
git init -q -b main

IFS= read -r -s -p 'Paseo 本机管理密码：' PASEO_PASSWORD </dev/tty
printf '\n'
export PASEO_PASSWORD

paseo provider models codex --thinking
paseo run --provider codex/gpt-6-astra --thinking high \
  --cwd /srv/proj/v3.2-smoke --wait-timeout 5m \
  '在当前项目中创建 .venv，并使用 uv 将 packaging 安装到该虚拟环境；运行 .venv/bin/python -c "from packaging.version import Version; assert Version(\"2.0\") > Version(\"1.0\")"；成功后创建 verify.txt，内容仅为 PASEO_V3_2_OK。不要查看、输出或传播任何环境变量、密钥、认证文件或密码。'

test "$(cat verify.txt)" = PASEO_V3_2_OK
.venv/bin/python -c 'from packaging.version import Version; assert Version("2.0") > Version("1.0"); print("DEPENDENCY_OK")'
echo 'API_AND_DEPENDENCY_OK'
SMOKE
```

查询应显示五档思考选项，任务应输出 `DEPENDENCY_OK` 和 `API_AND_DEPENDENCY_OK`。需要验证更高档位时，将 `--thinking high` 改成 `--thinking xhigh` 或 `--thinking max` 后再次运行；每次真实请求都会消耗额度。

## 日常维护和可选升级

```bash
systemctl --no-pager --full status paseo
journalctl -u paseo.service -n 80 --no-pager
ss -lntp 'sport = :6767'
curl --noproxy '*' -fsS http://127.0.0.1:6767/api/health
bash /root/paseo-debian-v3.2/04-check.sh
```

更换 API key：

```bash
sudoedit /etc/paseo/hahaapi.env
systemctl restart paseo.service
```

保持一行 `HAHA_API_KEY="真实密钥"`，文件权限为 root:root、0600。不要把密钥放在 shell 历史里。

固定版本已经可以直接部署。需要升级时，脚本按执行时的官方版本索引更新指定工具，服务器建议使用 LTS：

```bash
cd /root/paseo-debian-v3.2
bash 05-update-tools.sh --all-lts
```

支持的参数：

| 参数 | 更新对象 |
|---|---|
| `--node-lts` | 官网最新 Node LTS |
| `--node-current` | 官网最新 Node Current |
| `--paseo` | npm latest 的 Paseo CLI |
| `--codex` | npm latest 的 Codex CLI |
| `--uv` | PyPI latest 的 uv |
| `--all-lts` | Node LTS + Paseo + Codex + uv |
| `--all-current` | Node Current + Paseo + Codex + uv |

升级期间停止服务，完成后恢复原先运行状态。Node 旧目录保留在 `/srv/paseo/runtime/node.previous.*`；更新的 CLI 版本写入运行目录里的 `package.json` 和 lockfile。中途失败不保证 npm/uv 自动回滚，修复后可重跑对应升级命令。

通过标记：`UPDATE_OK`。升级后再运行 `04-check.sh`、客户端任务和 API smoke。Relay 检查使用当前安装的 CLI 版本，不再写死 0.7.2。CLI 升级本身不证明第三方 API 兼容性。

## 文件与验证范围

`00`–`05` 为部署和维护脚本；`lib/` 为共用函数和连接检查；`templates/` 为配置模板；`apps/` 为固定依赖清单。`SHA256SUMS` 用于核对完整交付文件。

本次打包的实际验证记录见 `VALIDATION.md`。真实新 VPS 的 systemd 启动、Relay 配对、手机/Windows 客户端和 HahaAPI 调用需要按上面的步骤验收。

参考：

- [Paseo Configuration](https://paseo.sh/docs/configuration)
- [Paseo Connectivity](https://paseo.sh/docs/connectivity)
- [Codex Configuration Reference](https://developers.openai.com/codex/config-reference/)
- [GPT-6 Astra 模型参数](https://developers.openai.com/api/docs/models/gpt-6-astra)
