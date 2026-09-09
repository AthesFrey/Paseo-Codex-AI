# Paseo Debian 部署教程 v3：Paseo Relay + 原生 Codex + Responses API

编写和源码核对日期：**2026 年 9 月 9 日**。

目标链路：

```text
手机 Paseo / Windows Paseo
          │ Paseo Relay（出站 TLS，端到端加密）
          ▼
VPS Paseo daemon：127.0.0.1:6767
          │ 本机 stdio 子进程
          ▼
原生 Codex CLI / codex app-server
          │ HTTPS Responses API
          ▼
https://sub2.hahaapi.com/v1
```

这是针对 Debian VPS 的 v3 安装包；首次使用建议在格式化后的全新机器执行，不包含旧服务迁移或兼容逻辑。Paseo Relay 不要求 VPN、端口转发或公网入站端口；daemon 主动向官方 Relay 建立出站连接，客户端通过配对二维码/链接接入。Relay 的业务负载由手机和 VPS 端到端加密，配对链接本身应当像密码一样保管。

所有批量脚本都按“可重复执行”设计：重复运行会复用已有的正确安装和配置；第 2 步会保留已有 `.profile`、API key 和 Paseo 密码，不再把它们误判为阻止条件。失败中断后直接重新运行对应步骤即可。只有 `05-update-tools.sh` 会按你选择的参数主动替换工具版本。若检测到配置 JSON 损坏、API key 文件权限不安全或账户 home 不符合 v3，脚本会停止并要求人工处理，不会盲目覆盖。
终端如果在粘贴多行命令时显示 `[200~`、`[201~` 或单独的 `~`，那是 SSH 终端的 bracketed-paste 控制标记被当成文字显示；它不是 Paseo、systemd 或防火墙错误。按 `Ctrl+C` 清掉当前输入，重新粘贴即可。

## 这版与防火墙的关系

你提供的防火墙管理脚本：

```text
https://raw.githubusercontent.com/AthesFrey/VPS_sh/main/firewall_nft_manager.sh
```

本次只读核对到的脚本行为是：普通 Apply 管理自己的 `inet filter` 表，input 默认 drop、output 默认 accept，并允许已建立连接回包；普通 Apply 不使用全局 `flush ruleset`。v3 不把任何 Paseo 规则写进这张表，也不修改它的 TCP/UDP 端口列表。

Relay 所需的网络条件只有：

| 方向 | 要求 |
|---|---|
| VPS 入站 TCP 6767 | **不需要开放** |
| VPS 入站任何 Relay 端口 | **不需要新增** |
| VPS 出站 DNS | 必须可用 |
| VPS 出站 TCP 443 到 `relay.paseo.sh` | 必须可用 |
| 已建立连接回包 | 必须可用 |

因此不要为了 Relay 在公网防火墙、安全组或你的端口管理脚本里添加 `6767`。也不需要 Tailscale 的 UDP 41641。下面的 `00-firewall-relay-check.sh` 是独立的只读检查：不执行 `nft add/insert/delete/flush`，不编辑 `/etc/nftables.conf`，不修改你的端口列表，也不 reload nftables。

如果你未来把出站策略改成默认拒绝，需要在你自己的**出站防火墙配置**中允许 DNS 和 TCP 443；不要把这些出站需求误写成 6767 入站规则。当前管理脚本生成 output `accept` 时，不需要额外 nft 配置。

## 开始前

- 全新 Debian 12（bookworm）或 Debian 13（trixie）。
- amd64/x86_64 或 arm64/aarch64；systemd 已启用。
- root SSH 会话，或能执行 `sudo -i`。
- 你已经用自己的防火墙脚本设置好 SSH 管理端口，并保留当前 SSH 会话。
- 供应商 API key 已准备好。不要把 key 发到聊天、截图、Git 或日志。
- 建议至少 2 vCPU、2 GiB RAM、8 GiB 可用空间；大型编译和浏览器测试需要更多资源。

把本目录完整上传到 VPS，例如：

```bash
/root/paseo-debian-v3/
```

不要只上传某一个 `.sh` 文件；脚本需要 `templates/`、`lib/` 和 `apps/package-lock.json`。

### 脚本重复执行规则

```text
00-firewall-relay-check.sh  只读，可重复
01-install.sh                补齐缺失基础组件，保留已升级工具
02-configure.sh              补齐缺失配置，保留已有 key/password/profile，重启并验收
03-pair.sh                   可重复生成配对材料，已有设备继续有效
04-check.sh                  只读，可重复
05-update-tools.sh           按参数主动升级，重复执行等同于再次检查/升级到当前目标
```

第 1 步不会把系统全局 npm 路径重新写入服务；第 2 步不会因为 `/srv/paseo/.profile` 存在而停止。

## 第 0 步：独立检查 Relay 所需防火墙条件

在你的防火墙管理脚本完成正常初始化/Apply 后执行：

```bash
cd /root/paseo-debian-v3
bash 00-firewall-relay-check.sh
```

它会检查：

- 当前 output 链是否明显允许出站/已建立回包；
- `relay.paseo.sh` 是否能解析；
- HTTPS/TCP 443 是否可达。

它不会打开端口，也不会改变规则。若它报告出站失败，先处理 DNS、云厂商出站策略或 nftables output；**不要**添加公网 TCP 6767。

**通过条件：**看到：

```text
FIREWALL_RELAY_CHECK_OK：未添加任何入站端口或 nftables 规则。
```

如果 output 链显示警告但 HTTPS 测试成功，仍可继续；这表示当前实际网络可用，但你应在后续变更防火墙后重新运行本检查。

## 第 1 步：安装基础依赖和固定版本工具

```bash
cd /root/paseo-debian-v3
bash 01-install.sh
```

脚本会安装：

- Git、Git LFS、ripgrep、jq、tmux、rsync；
- Python 3、venv、C/C++ 构建工具、`pkg-config`、OpenSSL/FFI 开发头文件；
- 固定的 Node.js 22.23.2；
- 固定的 Paseo CLI 0.7.2；
- 固定的 Codex CLI 0.153.4；
- 固定的 uv 0.12.11。

Node 官方压缩包会先按官方 `SHASUMS256.txt` 校验，再解压到 `/opt/paseo-v3/node`。Paseo/Codex 依赖使用包内 lockfile，通过 `npm ci` 安装到 `/opt/paseo-v3/apps`，不会依赖系统 npm 的全局前缀。

脚本只创建普通用户 `paseo`，不加入 `sudo`、`docker` 或 `lxd` 组。目录职责如下：

| 路径 | 用途 |
|---|---|
| `/opt/paseo-v3` | root 管理的固定程序和依赖 |
| `/srv/paseo/projects` | 项目仓库 |
| `/srv/paseo/worktrees` | Paseo 管理的 Git 工作树 |
| `/srv/paseo/tools` | 项目需要时的用户级工具链 |
| `/srv/paseo/cache` | npm、uv、编译、浏览器和临时缓存 |
| `/srv/paseo/.codex` | Codex 配置 |
| `/srv/paseo/.paseo` | Paseo 状态、会话和 daemon 密钥 |

**通过条件：**出现：

```text
STEP1_OK：基础依赖、Node、Paseo、Codex 和 uv 安装完成；没有启动网络服务。
```

脚本中途出错就停在本步；修复网络或磁盘问题后，直接重新运行 `01-install.sh`。它会保留已有且可执行的 Node/npm、Paseo/Codex npm 依赖和 uv 版本，不会因为重跑而降级你已经用第 5 步升级过的工具；如果某个安装不完整，会补齐该部分。

## 第 2 步：配置 Codex、API key、Paseo 密码并启动 daemon

保持 SSH 交互终端，执行（可以重复执行）：

```bash
cd /root/paseo-debian-v3
bash 02-configure.sh
```

首次运行且尚未存在对应文件时，脚本会要求：

1. 输入 `HAHA_API_KEY`，终端不回显；
2. 设置 Paseo daemon 连接密码，输入两次。

再次运行时，已有 API key 和密码哈希会复用，不会重复询问；已有 `/srv/paseo/.profile` 也会保留。配置文件缺失的部分会补齐，服务单元会刷新为 v3 模板并重启后验收。若上一次在输入密钥或密码时中断，直接重新运行；已有凭据不会被覆盖。

两者不是同一个密码：

| 凭据 | 用途 | 保存位置 |
|---|---|---|
| `HAHA_API_KEY` | Codex 调用第三方 Responses API | `/etc/paseo-v3/hahaapi.env`，root:root，0600 |
| Paseo 连接密码 | 本机 CLI 的 daemon 认证 | `/srv/paseo/.paseo/config.json` 中的 bcrypt 哈希 |
| Relay 配对链接 | 客户端取得 daemon 公钥并建立 E2EE 会话 | 只在配对时输出，不持久化到教程文件 |

生成的 Codex 配置等价于：

```toml
model = "gpt-6-astra"
model_provider = "hahaapi"
model_reasoning_effort = "high"
approval_policy = "never"
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
network_access = true
writable_roots = ["/srv/paseo/projects", "/srv/paseo/worktrees", "/srv/paseo/tools", "/srv/paseo/cache"]

[model_providers.hahaapi]
name = "HahaAPI"
base_url = "https://sub2.hahaapi.com/v1"
env_key = "HAHA_API_KEY"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
```

v3 默认关闭 Paseo 本地听写和语音模式，避免首次启动后台下载本地语音模型；这不影响文字编码任务。Paseo 的 Codex 模型目录只声明 `gpt-6-astra` 和 `High`，避免客户端默默选择供应商没有提供的模型。

daemon 的实际监听是：

```text
127.0.0.1:6767
```

这是 Relay 模式下的预期结果。不要把它改成 `0.0.0.0`，也不要向公网开放 6767。

**通过条件：**出现：

```text
STEP2_OK：Paseo 已健康运行在 127.0.0.1:6767，Relay 已启用。
```

并且：

```bash
systemctl --no-pager --full status paseo
ss -lntp 'sport = :6767'
curl --noproxy '*' -fsS http://127.0.0.1:6767/api/health
```

`ss` 只显示 `127.0.0.1:6767`。此时 Relay 控制连接可能仍在后台重试，下一步会单独检查出站 Relay 状态。

## 第 3 步：生成 Relay 配对二维码/链接

此步骤可以重复执行；每次都会生成新的配对材料，已配对设备继续保留。

执行：

```bash
cd /root/paseo-debian-v3
bash 03-pair.sh
```

脚本会：

1. 再次检查本机 daemon health；
2. 测试 `relay.paseo.sh:443` 的出站 HTTPS；
3. 使用本机 daemon 的 E2EE Relay 状态探针验证出站控制/数据路径；
4. 要求输入 Paseo daemon 连接密码；
5. 调用 `paseo daemon pair --relay`；
6. 在当前终端显示二维码和配对链接。

配对链接包含 daemon 的公钥和 Relay 地址，视同访问凭据：

- 只在自己的手机 Paseo 或 Windows Paseo 中使用；
- 不要发送到聊天、工单、Git、截图或日志；
- 不要把它当作 API key；
- 如果怀疑泄露，重新生成 daemon keypair 前应先停止服务并重新配对所有设备。

在手机或 Windows Paseo 中打开“添加/配对主机”流程，扫描二维码或粘贴该链接。客户端应自动取得 Relay 连接信息；不需要输入 Tailscale IP，不需要开启 `Use SSL` 开关，也不需要输入 HahaAPI key。

**通过条件：**看到：

```text
STEP3_LOCAL_OK：配对材料已生成；请在客户端完成配对后再执行 04-check.sh。
```

并且客户端中出现该 VPS 主机。此时不要把 VPS 当作客户端本机 daemon。

## 第 4 步：验收 Relay 和客户端连接

此步骤是只读检查，可以随时重复执行。

先在 VPS 执行：

```bash
cd /root/paseo-debian-v3
bash 04-check.sh
```

脚本会检查：

- systemd 服务是否以 `paseo` 用户 active 运行；
- 唯一监听是否为 `127.0.0.1:6767`；
- 本机 health 是否成功；
- Relay 配置、TLS 配置和密码哈希是否存在；
- `relay-check.mjs` 是否通过固定版本客户端完成一次 TLS/E2EE Relay 状态 RPC；
- 配对 daemon 的 `serverId` 是否与本机状态一致。

**通过条件：**出现：

```text
LOCAL_OK：paseo 用户运行，唯一回环监听 127.0.0.1:6767，health 与配置检查通过。
RELAY_OK：已通过 TLS/E2EE Relay 完成与本 daemon 的状态请求。未调用模型 API。
CHECK_OK：本机和 Relay 往返检查通过；手机/Windows 和第三方 API 仍要分别验收。
```

然后从已配对的手机或 Windows Paseo 发送一条简单消息。客户端能看到远程 daemon、创建项目并收到响应，才算跨设备 Relay 通道验收完成。

## 第 5 步：真实验证第三方 Responses API 和项目依赖

下面命令会消耗一次供应商 API 额度。它在 VPS 上创建一个隔离的 smoke 项目，并通过本机 Paseo CLI 连接已经运行的 daemon；API key 不会作为命令行参数传入：

```bash
runuser -u paseo -- bash <<'SMOKE'
set -Eeuo pipefail
export HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex PASEO_HOME=/srv/paseo/.paseo
export PATH=/opt/paseo-v3/apps/node_modules/.bin:/opt/paseo-v3/node/bin:/opt/paseo-v3/uv/bin:/srv/paseo/tools/bin:/usr/bin:/bin
mkdir -p /srv/paseo/projects/v3-smoke
cd /srv/paseo/projects/v3-smoke
git init -q -b main

IFS= read -r -s -p 'Paseo 连接密码：' PASEO_PASSWORD </dev/tty
printf '\n'
export PASEO_PASSWORD

paseo provider models codex --thinking
paseo run --provider codex/gpt-6-astra --thinking high \
  --cwd /srv/paseo/projects/v3-smoke --wait-timeout 5m \
  '在当前项目中创建 .venv，并使用 uv 将 packaging 安装到该虚拟环境；运行 .venv/bin/python -c "from packaging.version import Version; assert Version(\"2.0\") > Version(\"1.0\")"；成功后创建 verify.txt，文件内容仅为 PASEO_V3_OK。不要查看、输出或传播任何环境变量、密钥、认证文件或密码。'

test "$(cat verify.txt)" = PASEO_V3_OK
.venv/bin/python -c 'from packaging.version import Version; assert Version("2.0") > Version("1.0"); print("DEPENDENCY_OK")'
echo 'API_AND_DEPENDENCY_OK'
SMOKE
```

**最终通过条件：**

- Windows/手机 Paseo 可以通过 Relay 打开 VPS 主机；
- `04-check.sh` 输出 `RELAY_OK` 和 `CHECK_OK`；
- smoke 输出 `DEPENDENCY_OK` 和 `API_AND_DEPENDENCY_OK`；
- 任务确实使用 `gpt-6-astra`，而不是客户端本机或其他 provider。

最后可以用你的防火墙管理脚本执行一次**普通** Apply，再重复 `04-check.sh` 和客户端任务测试。因为 v3 不写入它的 managed table，这次测试用于证明你的防火墙变更没有阻断 VPS 出站 HTTPS 或已建立连接回包。不要用 Emergency Initialize 作为日常 Apply。

## 依赖安装和权限策略

v3 的默认策略是：

- Codex 使用 `approval_policy = "never"` 和 `sandbox_mode = "workspace-write"`；
- 项目目录、worktree、工具目录、缓存目录可写；
- 项目命令可以联网；
- API key 不被普通 shell 子进程默认继承；
- systemd 服务使用普通用户 `paseo`、`NoNewPrivileges=true`、`ProtectSystem=strict`、`ProtectHome=true`；
- 不提供 sudoers 免密码规则，不挂 Docker socket。

给项目 agent 的基本约定：

```text
先检查已有 manifest 和 lockfile，再按项目需要安装局部依赖；不要全局 sudo pip，不要改 apt 源，不要修改 sudoers、防火墙、systemd 或 /etc，不要读取或输出任何 key/password/token。
```

推荐做法：

| 项目类型 | 优先动作 | 位置 |
|---|---|---|
| Python | `uv sync`、`uv add`、项目 `.venv` | 项目目录 |
| 新 Python | `uv python install 3.12` | `/srv/paseo/tools/python` |
| Python CLI | `uv tool install ruff` | `/srv/paseo/tools/uv`、`tools/bin` |
| Node | 遵守 lockfile 使用 `npm ci`/项目指定包管理器 | 项目 `node_modules` |
| 用户级 Node 工具 | `npm install -g <工具>` | `npm_config_prefix=/srv/paseo/tools` |
| Rust/Go | 按项目版本安装到 tools，更新项目清单 | `/srv/paseo/tools` |

如果缺少系统头文件或库，agent 应报告确切包名和原因，由管理员 SSH 执行：

```bash
apt-get update
apt-get install -y --no-install-recommends cmake ninja-build libpq-dev libsqlite3-dev
```

这是按项目需要的示例，不是固定必装项。不要让 agent 通过 root 运行 Paseo 来绕过系统包权限。

对可信项目偶尔需要更宽权限时，可以在 Paseo 客户端针对单个任务选择 `Full Access`；使用结束后恢复默认模式。它会扩大 Codex 的文件和命令边界，仍然不是项目隔离机制，也不应对陌生仓库、未审查脚本或不可信提示词使用。

## 日常维护

```bash
# 状态和日志
systemctl --no-pager --full status paseo
journalctl -u paseo.service -n 100 --no-pager
ss -lntp 'sport = :6767'

# Relay 状态只查看，不输出凭据
journalctl -u paseo.service --no-pager -b | grep -E 'relay_(control|data)_(connected|disconnected)|relay_error' | tail -30

# 防火墙只读复查
bash /root/paseo-debian-v3/00-firewall-relay-check.sh

# 服务配置摘要（不显示 key 文件内容）
stat -c '%a %U:%G %n' /etc/paseo-v3/hahaapi.env /etc/paseo-v3/runtime.env   /srv/paseo/.codex/config.toml /srv/paseo/.paseo/config.json
```

更换 API key：

```bash
sudoedit /etc/paseo-v3/hahaapi.env
systemctl restart paseo.service
```

文件保持一行 `HAHA_API_KEY="真实密钥"`，权限保持 root:root、0600；不要使用 `echo key > ...` 把 key 放进 shell 历史或日志。

重启 VPS 后验收顺序：

```bash
systemctl is-active paseo
curl --noproxy '*' -fsS http://127.0.0.1:6767/api/health
journalctl -u paseo.service --no-pager -b | grep relay_control_connected
bash /root/paseo-debian-v3/04-check.sh
```

如果只看到本机 health 成功但客户端不通，优先检查出站 DNS/TCP 443、Relay 日志、配对链接是否来自当前 daemon，以及客户端是否连接了正确主机；不要先开放 6767。

## 安全边界

- Relay 服务看到的是连接元数据和密文，配对端点才拥有解密所需的密钥；配对链接仍然必须保密。
- `HAHA_API_KEY` 由 daemon 进程持有。不要把不可信仓库交给这个服务账号，因为代码执行能力和 API 凭据同处一个 daemon 用户边界。
- 不把 `/etc`、`/root`、生产数据目录、Docker socket 或其他密钥目录加入 Codex writable roots。
- `approval_policy = "never"` 表示命令执行不逐条询问，不表示代码、依赖或删除操作自动可信；使用 Git 分支/worktree，执行后查看 diff 和测试。
- 不在日志命令中使用 `env`、`printenv`、`systemctl show -p Environment` 或 `curl -v`。

## 交付包和验证范围

- `00-firewall-relay-check.sh`：只读出站检查。
- `01-install.sh`：基础安装和可重复补齐。
- `02-configure.sh`：配置补齐、按需输入密钥/密码、systemd 服务启动。
- `03-pair.sh`：Relay 出站检查和可重复配对二维码/链接。
- `04-check.sh`：可重复的本机、Relay TLS/E2EE 往返连接和文件权限验收。
- `05-update-tools.sh`：强制更新 Node.js、Paseo CLI、Codex CLI 或 uv；可重复执行。
- `templates/`：Codex、Paseo、systemd 和运行环境模板。
- `apps/package-lock.json`：固定 CLI 依赖图。

本地已检查 Bash/Python 语法、Paseo 配置 schema、Codex 配置 schema、lockfile `npm ci`、systemd 模板字段、Relay 命令失败路径、API key 文件处理和 ZIP 完整性。没有使用你的真实 VPS、Tailnet、API key 或客户端；真实环境必须按每一步的通过条件验收。

### 参考来源

- Paseo Connectivity：`https://paseo.sh/docs/connectivity`
- Paseo Security / Relay：`https://paseo.sh/docs/security`
- Paseo Configuration：`https://paseo.sh/docs/configuration`
- Paseo 0.7.2 发布包：`https://registry.npmjs.org/@getpaseo/cli/0.7.2`
- Codex Configuration Reference：`https://developers.openai.com/codex/config-reference/`
- Codex 0.153.4 发布包：`https://registry.npmjs.org/@openai/codex/0.153.4`
- Node.js 22.23.2 校验清单：`https://nodejs.org/dist/v22.23.2/SHASUMS256.txt`
- uv 0.12.11：`https://pypi.org/project/uv/0.12.11/`
- 你的防火墙脚本：`https://raw.githubusercontent.com/AthesFrey/VPS_sh/main/firewall_nft_manager.sh`

## 强制升级工具

你可以接受升级失败后重装 VPS，因此 v3 提供了强制升级脚本。它只更新 `/opt/paseo-v3` 下的 Node、Paseo、Codex、uv 和 npm lockfile，不修改 `/srv/paseo/.paseo`、`/srv/paseo/.codex`、API key、Relay 配对状态或防火墙规则。

当前版本检查日期为 **2026 年 9 月 9 日**：npm 的 `@getpaseo/cli@latest` 是 `0.7.2`，`@openai/codex@latest` 是 `0.153.4`，PyPI 的 `uv` 是 `0.12.11`；Node 官方索引的最新 Current 是 `v26.8.1`，最新 LTS 是 `v24.21.0`。因此当前 Paseo/Codex/uv 的 `latest` 仍等于 v3 固定版本，Node 才有升级差异。发布状态会变化，脚本每次运行时重新查询官网。[U1][U2][U3][U4]

### 一条命令升级全部

升级到 Node 最新 Current：

```bash
cd /root/paseo-debian-v3
sudo bash 05-update-tools.sh --all-current
```

升级到 Node 最新 LTS：

```bash
cd /root/paseo-debian-v3
sudo bash 05-update-tools.sh --all-lts
```

我更建议服务器使用 LTS；你明确接受稳定性风险时再使用 Current。

### 单独升级

只升级 Paseo CLI：

```bash
sudo bash /root/paseo-debian-v3/05-update-tools.sh --paseo
```

只升级 Codex CLI：

```bash
sudo bash /root/paseo-debian-v3/05-update-tools.sh --codex
```

只升级 uv：

```bash
sudo bash /root/paseo-debian-v3/05-update-tools.sh --uv
```

Node 升级到最新 Current：

```bash
sudo bash /root/paseo-debian-v3/05-update-tools.sh --node-current
```

Node 升级到最新 LTS：

```bash
sudo bash /root/paseo-debian-v3/05-update-tools.sh --node-lts
```

脚本会先停止 Paseo。Node 会从 Node 官方索引选版本，并校验该版本的 `SHASUMS256.txt`；旧 Node 目录会保留为 `/opt/paseo-v3/node.previous.YYYYMMDD-HHMMSS`。Paseo/Codex 会用 `npm install --save-exact --force` 更新 `package.json` 和 `package-lock.json`，然后再执行一次 `npm ci --force`。uv 会在 v3 自己的 Python venv 内强制重装最新版。

升级完成后，脚本会检查四个版本，重新启动原本 active 的 Paseo 服务，并等待：

```text
UPDATE_OK：工具升级完成，Paseo 服务已恢复且本机 health 成功。
```

如果升级前服务是 stopped，脚本会保持 stopped；如果升级后 health 失败，会打印 systemd 状态和最近日志，但不会偷偷恢复旧 npm 依赖。你可以直接重装系统，也可以先查看备份：

```bash
ls -ld /opt/paseo-v3/node.previous.*
cat /opt/paseo-v3/apps/package.json
```

### 手动确认版本

```bash
sudo -u paseo env HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex \
  PATH=/opt/paseo-v3/apps/node_modules/.bin:/opt/paseo-v3/node/bin:/usr/bin:/bin \
  /opt/paseo-v3/apps/node_modules/.bin/paseo --version

sudo -u paseo env HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex \
  PATH=/opt/paseo-v3/apps/node_modules/.bin:/opt/paseo-v3/node/bin:/usr/bin:/bin \
  /opt/paseo-v3/apps/node_modules/.bin/codex --version

/opt/paseo-v3/uv/bin/uv --version
/opt/paseo-v3/node/bin/node --version
```

升级 Node、Paseo 或 Codex 后，必须重新执行：

```bash
sudo bash /root/paseo-debian-v3/04-check.sh
```

再从手机/Windows Paseo 发一条最小任务，最后运行真实 API smoke。升级 CLI 版本不会自动验证第三方 Responses API 的参数兼容性。

[U1] npm registry 的 `@getpaseo/cli` latest：
`https://registry.npmjs.org/@getpaseo/cli/latest`

[U2] npm registry 的 `@openai/codex` latest：
`https://registry.npmjs.org/@openai/codex/latest`

[U3] Node.js 官方发行索引：
`https://nodejs.org/dist/index.json`

[U4] PyPI 的 uv：
`https://pypi.org/pypi/uv/json`
