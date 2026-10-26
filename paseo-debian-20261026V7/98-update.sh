#!/usr/bin/env bash
# Update the Paseo runtime to the current official releases.
set -Eeuo pipefail
umask 022

readonly PACKAGE_ID='paseo-debian'
readonly PACKAGE_VERSION='1.0.0'
readonly PASEO_KIT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PASEO_ROOT='/srv/paseo/runtime'
readonly APPS_ROOT="$PASEO_ROOT/apps"
readonly NODE_ROOT="$PASEO_ROOT/node"
readonly UV_ROOT="$PASEO_ROOT/uv/bin"
readonly CODEX_HOME='/srv/paseo/.codex'
readonly CODEX_BIN='/srv/paseo/tools/bin/codex'
readonly PASEO_HOME='/srv/paseo/.paseo'
readonly PASEO_ETC='/etc/paseo'
readonly SERVICE_UNIT='/etc/systemd/system/paseo.service'
readonly CACHE_ROOT='/srv/paseo/cache'
readonly CACHE_TMP="$CACHE_ROOT/tmp"
readonly PROJECT_ROOT='/srv/proj'
readonly WORKTREE_ROOT='/srv/paseo/worktrees'
readonly INSTALL_STATE="$PASEO_ROOT/.install-complete"
readonly CODEX_AUTO_UPDATE="$CODEX_HOME/packages/standalone/auto-update-version"
readonly LOCK_PATH='/run/lock/paseo-debian-update.lock'
readonly RUNTIME_PATH="$APPS_ROOT/node_modules/.bin:$NODE_ROOT/bin:$UV_ROOT:/srv/paseo/tools/bin:/srv/paseo/tools/cargo/bin:/srv/paseo/tools/go/bin:/usr/local/bin:/usr/bin:/bin"

stage=''
backup=''
transaction_started=no
update_succeeded=no
preserve_stage=no
service_was_active=no
old_codex_link_target=''
old_codex_link_owner=''
old_codex_current_target=''
old_codex_current_owner=''
old_codex_auto_update_exists=no
old_codex_target=''
old_codex_release_dir=''

fail() {
  echo "更新失败：$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "找不到命令：$1"
}

require_directory_mode() {
  local path="$1" expected="$2"
  [[ -d "$path" && ! -L "$path" ]] || fail "目录不存在或不是普通目录：$path"
  [[ "$(stat -c '%u:%g:%a' -- "$path")" == "$expected" ]] \
    || fail "目录属主或权限错误（应为 $expected）：$path"
}

require_file_mode() {
  local path="$1" expected="$2"
  [[ -f "$path" && ! -L "$path" ]] || fail "文件不存在或不是普通文件：$path"
  [[ "$(stat -c '%u:%g:%a' -- "$path")" == "$expected" ]] \
    || fail "文件属主或权限错误（应为 $expected）：$path"
}

state_value() {
  local key="$1"
  awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$INSTALL_STATE"
}

run_as_paseo_with_path() {
  local path_value="$1"
  shift
  runuser -u paseo -- env -i \
    HOME=/srv/paseo USER=paseo LOGNAME=paseo SHELL=/bin/bash \
    CODEX_HOME="$CODEX_HOME" PASEO_HOME="$PASEO_HOME" PASEO_RUNTIME_ROOT="$PASEO_ROOT" \
    TMPDIR="$CACHE_TMP" XDG_CACHE_HOME="$CACHE_ROOT" \
    npm_config_cache="$CACHE_ROOT/npm-paseo" \
    npm_config_prefix=/srv/paseo/tools \
    npm_config_userconfig=/dev/null npm_config_registry=https://registry.npmjs.org/ \
    UV_CACHE_DIR="$CACHE_ROOT/uv" \
    UV_PYTHON_INSTALL_DIR=/srv/paseo/tools/python \
    UV_TOOL_DIR=/srv/paseo/tools/uv \
    UV_TOOL_BIN_DIR=/srv/paseo/tools/bin \
    PIP_CACHE_DIR="$CACHE_ROOT/pip" \
    CARGO_HOME=/srv/paseo/tools/cargo RUSTUP_HOME=/srv/paseo/tools/rustup \
    GOPATH=/srv/paseo/tools/go GOMODCACHE="$CACHE_ROOT/gomod" \
    GOCACHE="$CACHE_ROOT/go-build" \
    PLAYWRIGHT_BROWSERS_PATH="$CACHE_ROOT/ms-playwright" \
    PATH="$path_value" \
    /bin/bash --noprofile --norc -c \
    'set -Eeuo pipefail; cd -- /srv/proj; exec "$@"' \
    paseo-update-runner "$@"
}

run_as_paseo() {
  run_as_paseo_with_path "$RUNTIME_PATH" "$@"
}

json_value() {
  local file="$1" expression="$2"
  python3 - "$file" "$expression" <<'PY'
import json
import re
import sys

path, expression = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
if expression == "node":
    for item in data:
        version = item.get("version", "")
        if item.get("lts") and re.fullmatch(
            r"v[0-9]+\.[0-9]+\.[0-9]+", version
        ):
            print(version[1:])
            print(item.get("npm", ""))
            break
    else:
        raise SystemExit("Node.js 最新 LTS 正式发行版未找到。")
elif expression == "npm":
    version = data.get("version", "")
    engines = data.get("engines", {}).get("node", "")
    if (
        not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
        or not engines
    ):
        raise SystemExit("npm registry latest 元数据不完整。")
    print(version)
    print(engines)
else:
    raise SystemExit(f"未知版本元数据类型：{expression}")
PY
}

check_node_engine() {
  python3 - "$1" "$2" <<'PY'
import re
import sys

node, expression = sys.argv[1:]
node_parts = tuple(map(int, node.split(".")))


def version(value):
    match = re.fullmatch(r"v?(\d+)(?:\.(\d+))?(?:\.(\d+))?", value.strip())
    if not match:
        return None
    return tuple(int(part or 0) for part in match.groups())


def satisfies_clause(clause):
    clause = clause.strip()
    if not clause or clause in ("*", "x", "X"):
        return True
    tokens = clause.replace(",", " ").split()
    for token in tokens:
        if token.startswith("^"):
            base = version(token[1:])
            if base is None:
                return False
            if base[0] > 0:
                upper = (base[0] + 1, 0, 0)
            elif base[1] > 0:
                upper = (0, base[1] + 1, 0)
            else:
                upper = (0, 0, base[2] + 1)
            if not (node_parts >= base and node_parts < upper):
                return False
            continue
        if token.startswith("~"):
            base = version(token[1:])
            if base is None or not (node_parts >= base and node_parts < (base[0], base[1] + 1, 0)):
                return False
            continue
        match = re.match(r"^(>=|<=|>|<|=)?(.*)$", token)
        op, raw = match.groups()
        base = version(raw)
        if base is None:
            wildcard = re.fullmatch(
                r"(\d+|x|X|\*)(?:\.(\d+|x|X|\*))?(?:\.(\d+|x|X|\*))?", raw
            )
            if not wildcard:
                return False
            for actual, expected in zip(node_parts, wildcard.groups()):
                if expected is None or expected.lower() in ("x", "*"):
                    break
                if actual != int(expected):
                    return False
            continue
        if op == ">=" and node_parts < base:
            return False
        if op == "<=" and node_parts > base:
            return False
        if op == ">" and node_parts <= base:
            return False
        if op == "<" and node_parts >= base:
            return False
        if op in (None, "=") and node_parts != base:
            return False
    return True


if not any(satisfies_clause(clause) for clause in expression.split("||")):
    raise SystemExit(f"Node.js v{node} 不满足 npm@latest 的 engines.node: {expression}")
PY
}

read_lock_metadata() {
  mapfile -t lock_metadata < <(python3 - "$1" <<'PY'
import json
import sys

lock = json.load(open(sys.argv[1], encoding="utf-8"))
root = lock.get("packages", {}).get("")
if not isinstance(root, dict) or root.get("dependencies") != {"@getpaseo/cli": "latest"}:
    raise SystemExit("Paseo lockfile 根依赖声明不正确。")
items = []
for name, item in lock.get("packages", {}).items():
    if not name.startswith("node_modules/") or not item.get("hasInstallScript"):
        continue
    package = name.removeprefix("node_modules/")
    items.append(f"{package}@{item.get('version', '')}")
print(",".join(sorted(items)))
PY
)
  [[ ${#lock_metadata[@]} == 1 ]] || return 1
  native_packages="${lock_metadata[0]}"
}

snapshot_protected_files() {
  install -d -o root -g root -m 0700 "$protected_snapshot_dir"
  : > "$protected_metadata_snapshot"
  local path index=0
  for path in "${protected_files[@]}"; do
    index=$((index + 1))
    if [[ -L "$path" ]]; then
      fail "受保护路径不允许是符号链接：$path"
    elif [[ -f "$path" ]]; then
      cp -- "$path" "$protected_snapshot_dir/$index"
      printf '%s\t%s\t%s\n' "$path" "$index" "$(stat -c '%u:%g:%a' -- "$path")" \
        >> "$protected_metadata_snapshot"
    elif [[ -e "$path" ]]; then
      fail "受保护路径必须是普通文件：$path"
    else
      printf '%s\tABSENT\n' "$path" >> "$protected_metadata_snapshot"
    fi
  done
}

verify_protected_files() {
  local path snapshot expected
  while IFS=$'\t' read -r path snapshot expected; do
    if [[ "$snapshot" == ABSENT ]]; then
      [[ ! -e "$path" && ! -L "$path" ]] || return 1
    else
      [[ -f "$path" && ! -L "$path" ]] || return 1
      cmp -s -- "$protected_snapshot_dir/$snapshot" "$path" || return 1
      [[ "$(stat -c '%u:%g:%a' -- "$path")" == "$expected" ]] || return 1
    fi
  done < "$protected_metadata_snapshot"
}

restore_item() {
  local destination="$1" saved="$2"
  if [[ -e "$saved" || -L "$saved" ]]; then
    rm -rf -- "$destination"
    mv -- "$saved" "$destination"
  fi
}

restore_codex_state() {
  local restore_status=0
  set +e
  if [[ -n "$old_codex_release_dir" && ! -d "$old_codex_release_dir" ]]; then
    mkdir -p -- "$(dirname -- "$old_codex_release_dir")" || restore_status=1
    cp -a -- "$backup/codex-release" "$old_codex_release_dir" || restore_status=1
  fi
  rm -f -- "$CODEX_BIN"
  ln -s -- "$old_codex_link_target" "$CODEX_BIN" || restore_status=1
  chown -h -- "$old_codex_link_owner" "$CODEX_BIN" || restore_status=1
  rm -f -- "$CODEX_HOME/packages/standalone/current"
  ln -s -- "$old_codex_current_target" "$CODEX_HOME/packages/standalone/current" || restore_status=1
  chown -h -- "$old_codex_current_owner" "$CODEX_HOME/packages/standalone/current" || restore_status=1
  if [[ "$old_codex_auto_update_exists" == yes ]]; then
    restore_item "$CODEX_AUTO_UPDATE" "$backup/codex-auto-update-version" || restore_status=1
  else
    rm -f -- "$CODEX_AUTO_UPDATE"
  fi
  set -e
  return "$restore_status"
}

rollback() {
  local rollback_status=0
  set +e
  systemctl stop paseo.service >/dev/null 2>&1 || rollback_status=1
  restore_item "$NODE_ROOT" "$backup/node" || rollback_status=1
  restore_item "$APPS_ROOT/node_modules" "$backup/apps-node_modules" || rollback_status=1
  restore_item "$APPS_ROOT/package.json" "$backup/apps-package.json" || rollback_status=1
  restore_item "$APPS_ROOT/package-lock.json" "$backup/apps-package-lock.json" || rollback_status=1
  restore_item "$UV_ROOT/uv" "$backup/uv" || rollback_status=1
  restore_item "$UV_ROOT/uvx" "$backup/uvx" || rollback_status=1
  if [[ -f "$backup/install-complete" ]]; then
    install -o root -g root -m 0644 "$backup/install-complete" "$INSTALL_STATE" || rollback_status=1
  fi
  restore_codex_state || rollback_status=1
  if [[ "$service_was_active" == yes ]]; then
    systemctl start paseo.service >/dev/null 2>&1 || rollback_status=1
  fi
  transaction_started=no
  set -e
  return "$rollback_status"
}

on_exit() {
  local status=$?
  trap - EXIT
  if [[ "$transaction_started" == yes && "$update_succeeded" != yes ]]; then
    echo '更新未完成，正在恢复更新前的运行时。' >&2
    if ! rollback; then
      echo "旧运行时恢复失败；回滚暂存目录保留在：$stage" >&2
      preserve_stage=yes
      status=1
    else
      echo '旧运行时已恢复。' >&2
    fi
  fi
  if [[ "$preserve_stage" != yes && -n "$stage" && -d "$stage" ]]; then
    rm -rf -- "$stage"
  fi
  rm -f -- "$INSTALL_STATE.update"
  if [[ "$status" == 0 && "$update_succeeded" == yes ]]; then
    echo "UPDATE_OK：Paseo 已更新到 Node.js $node_version、npm $npm_version、Paseo $paseo_version、Codex $codex_version 和 uv $uv_version。"
  fi
  exit "$status"
}
trap on_exit EXIT

[[ $EUID == 0 ]] || fail '请以 root 或 sudo bash 执行。'
for command in awk cat chmod chown cmp cp curl cut find flock getent grep head id install ln mktemp mv python3 readlink rm runuser sort stat systemctl systemd-analyze tail tar uname xz; do
  require_command "$command"
done

[[ -r /etc/os-release ]] || fail '无法读取 /etc/os-release。'
# shellcheck disable=SC1091
source /etc/os-release
[[ "$ID" == debian && "${VERSION_CODENAME:-}" =~ ^(bookworm|trixie)$ ]] \
  || fail "仅支持 Debian 12 (bookworm) 或 Debian 13 (trixie)。检测到：${PRETTY_NAME:-unknown}"

case "$(uname -m)" in
  x86_64) node_arch=x64 ;;
  aarch64) node_arch=arm64 ;;
  *) fail '仅支持 amd64 (x86_64) 或 arm64 (aarch64)。' ;;
esac

id paseo >/dev/null 2>&1 || fail '缺少 paseo 用户；请先执行工具包全新安装。'
[[ "$(getent passwd paseo | cut -d: -f6)" == /srv/paseo ]] || fail 'paseo 用户 home 必须是 /srv/paseo。'
paseo_uid="$(id -u paseo)"
paseo_gid="$(id -g paseo)"
require_directory_mode /srv/paseo "$paseo_uid:$paseo_gid:700"
require_directory_mode "$PASEO_ROOT" '0:0:755'
require_directory_mode "$APPS_ROOT" '0:0:755'
require_directory_mode "$NODE_ROOT" '0:0:755'
require_directory_mode "$PASEO_ROOT/uv" '0:0:755'
require_directory_mode "$UV_ROOT" '0:0:755'
require_directory_mode "$APPS_ROOT/node_modules" '0:0:755'
[[ -d "$PROJECT_ROOT" && ! -L "$PROJECT_ROOT" ]] || fail "项目目录不存在或不是普通目录：$PROJECT_ROOT"
require_directory_mode "$WORKTREE_ROOT" "$paseo_uid:$paseo_gid:700"
require_directory_mode "$CODEX_HOME" "$paseo_uid:$paseo_gid:700"
require_directory_mode "$PASEO_HOME" "$paseo_uid:$paseo_gid:700"
require_directory_mode /srv/paseo/tools "$paseo_uid:$paseo_gid:700"
require_directory_mode /srv/paseo/tools/bin "$paseo_uid:$paseo_gid:700"
require_directory_mode "$PASEO_ETC" '0:0:700'
require_directory_mode "$CACHE_ROOT" "$paseo_uid:$paseo_gid:700"
require_directory_mode "$CACHE_TMP" "$paseo_uid:$paseo_gid:700"
require_file_mode "$INSTALL_STATE" '0:0:644'
[[ "$(state_value package)" == "$PACKAGE_ID" ]] || fail '安装记录不属于 paseo-debian；停止更新。'
[[ -f "$PASEO_ETC/.configured" ]] || fail '缺少配置完成标记；请先完成 02-configure.sh。'
require_file_mode "$PASEO_ETC/.configured" '0:0:644'
require_file_mode "$PASEO_HOME/config.json" "$paseo_uid:$paseo_gid:600"
require_file_mode "$CODEX_HOME/config.toml" "$paseo_uid:$paseo_gid:600"
require_file_mode "$PASEO_ETC/runtime.env" '0:0:644'
require_file_mode "$PASEO_ETC/hahaapi.env" '0:0:600'
if [[ -e "$PASEO_ETC/backapi.env" || -L "$PASEO_ETC/backapi.env" ]]; then
  require_file_mode "$PASEO_ETC/backapi.env" '0:0:600'
fi
require_file_mode "$SERVICE_UNIT" '0:0:644'
systemd-analyze verify "$SERVICE_UNIT" >/dev/null
grep -Fq 'Description=Paseo Relay daemon' "$SERVICE_UNIT" || fail 'systemd unit 不是 Paseo 托管 unit。'
grep -Fq '/srv/paseo/runtime/apps/node_modules/@getpaseo/cli/bin/paseo daemon run --home /srv/paseo/.paseo' "$SERVICE_UNIT" \
  || fail 'systemd unit 的 Paseo 启动路径不正确。'

package_json="$APPS_ROOT/package.json"
require_file_mode "$package_json" '0:0:644'
require_file_mode "$APPS_ROOT/package-lock.json" '0:0:644'
[[ ! -e "$APPS_ROOT/.npmrc" && ! -L "$APPS_ROOT/.npmrc" ]] || fail '运行时目录中不应保留临时 .npmrc。'
python3 - "$package_json" <<PY
import json
import sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
assert data.get('version') == '$PACKAGE_VERSION'
assert data.get('dependencies') == {'@getpaseo/cli': 'latest'}
PY
for state_key in node npm paseo codex uv; do
  [[ -n "$(state_value "$state_key")" ]] || fail "安装记录缺少组件版本：$state_key"
done
[[ "$(state_value codex_home)" == "$CODEX_HOME" && "$(state_value codex_bin)" == "$CODEX_BIN" ]] \
  || fail '安装记录中的 Codex 路径不是 Paseo 托管布局。'
read_lock_metadata "$APPS_ROOT/package-lock.json" || fail '当前 Paseo lockfile 校验失败。'
[[ "$(state_value native_packages)" == "$native_packages" ]] \
  || fail '当前 native 依赖清单与安装记录不一致。'
[[ -x "$NODE_ROOT/bin/node" && -x "$NODE_ROOT/bin/npm" \
  && -x "$APPS_ROOT/node_modules/.bin/paseo" \
  && -x "$UV_ROOT/uv" && -x "$UV_ROOT/uvx" ]] \
  || fail '当前运行时缺少 Node.js、npm、Paseo CLI 或 uv 可执行文件。'
old_node_version="$(state_value node)"
old_npm_version="$(state_value npm)"
old_paseo_version="$(state_value paseo)"
old_codex_version="$(state_value codex)"
old_uv_version="$(state_value uv)"
[[ "$(run_as_paseo "$NODE_ROOT/bin/node" --version)" == "v$old_node_version" ]] \
  || fail '当前 Node.js 与安装记录不一致。'
[[ "$(run_as_paseo "$NODE_ROOT/bin/npm" --version)" == "$old_npm_version" ]] \
  || fail '当前 npm 与安装记录不一致。'
current_paseo_version="$(run_as_paseo "$APPS_ROOT/node_modules/.bin/paseo" --version \
  | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1)"
[[ "$current_paseo_version" == "$old_paseo_version" ]] \
  || fail '当前 Paseo CLI 与安装记录不一致。'
[[ "$(run_as_paseo "$UV_ROOT/uv" --version)" == "uv $old_uv_version "* ]] \
  || fail '当前 uv 与安装记录不一致。'

for cache_name in tmp npm-paseo pip uv gomod go-build ms-playwright; do
  cache_path="$CACHE_ROOT/$cache_name"
  require_directory_mode "$cache_path" "$paseo_uid:$paseo_gid:700"
done

[[ -d /run/lock && ! -L /run/lock ]] || fail '系统锁目录 /run/lock 不可用。'
if [[ -e "$LOCK_PATH" || -L "$LOCK_PATH" ]]; then
  require_file_mode "$LOCK_PATH" '0:0:600'
else
  install -o root -g root -m 0600 /dev/null "$LOCK_PATH"
fi
[[ ! -L "$LOCK_PATH" ]] || fail '更新锁路径不允许是符号链接。'
exec 9>>"$LOCK_PATH"
chmod 0600 "$LOCK_PATH"
flock -n 9 || fail '已有另一个 Paseo 更新正在执行。'

if systemctl is-active --quiet paseo.service; then
  service_was_active=yes
fi

stage="$(mktemp -d "$CACHE_TMP/paseo-debian-update.XXXXXX")"
chown paseo:paseo "$stage"
chmod 0700 "$stage"
backup="$stage/backup"
install -d -o root -g root -m 0700 "$backup"
protected_snapshot_dir="$stage/protected"
protected_metadata_snapshot="$stage/protected.metadata"
protected_files=(
  "$PASEO_HOME/config.json"
  "$CODEX_HOME/config.toml"
  "$PASEO_ETC/runtime.env"
  "$PASEO_ETC/hahaapi.env"
  "$PASEO_ETC/backapi.env"
  "$SERVICE_UNIT"
  "$APPS_ROOT/backapi-codex-wrapper"
  /etc/systemd/system/paseo.service.d/10-backapi.conf
)
snapshot_protected_files
project_identity_before="$(stat -c '%d:%i' "$PROJECT_ROOT")"
worktree_identity_before="$(stat -c '%d:%i' "$WORKTREE_ROOT")"
project_metadata_before="$(stat -c '%u:%g:%a' "$PROJECT_ROOT")"
worktree_metadata_before="$(stat -c '%u:%g:%a' "$WORKTREE_ROOT")"

[[ -L "$CODEX_BIN" ]] || fail 'Codex 管理链接缺失。'
[[ -L "$CODEX_HOME/packages/standalone/current" ]] || fail 'Codex standalone current 链接缺失。'
[[ "$(stat -c '%u:%g' -- "$CODEX_BIN")" == "$paseo_uid:$paseo_gid" ]] \
  || fail 'Codex 管理链接必须由 paseo 用户持有。'
[[ "$(stat -c '%u:%g' -- "$CODEX_HOME/packages/standalone/current")" == "$paseo_uid:$paseo_gid" ]] \
  || fail 'Codex standalone current 链接必须由 paseo 用户持有。'
old_codex_link_target="$(readlink "$CODEX_BIN")"
old_codex_link_owner="$(stat -c '%u:%g' "$CODEX_BIN")"
old_codex_current_target="$(readlink "$CODEX_HOME/packages/standalone/current")"
old_codex_current_owner="$(stat -c '%u:%g' "$CODEX_HOME/packages/standalone/current")"
old_codex_target="$(readlink -f "$CODEX_BIN")"
[[ "$old_codex_target" == "$CODEX_HOME/packages/standalone/"* \
  && -f "$old_codex_target" && -x "$old_codex_target" ]] \
  || fail 'Codex 管理链接未指向官方 standalone 文件。'
current_codex_target="$(readlink -f "$CODEX_HOME/packages/standalone/current")"
[[ "$current_codex_target" == "$CODEX_HOME/packages/standalone/"* && -d "$current_codex_target" ]] \
  || fail 'Codex standalone current 未指向托管 release 目录。'
[[ "$(dirname -- "$old_codex_target")" == "$current_codex_target/bin" ]] \
  || fail 'Codex 管理链接与 standalone current 不一致。'
old_codex_release_dir="$current_codex_target"
cp -a -- "$old_codex_release_dir" "$backup/codex-release"
[[ "$(run_as_paseo "$CODEX_BIN" --version)" == "codex-cli $old_codex_version" ]] \
  || fail '当前 Codex CLI 与安装记录不一致。'
if [[ -e "$CODEX_AUTO_UPDATE" || -L "$CODEX_AUTO_UPDATE" ]]; then
  [[ -f "$CODEX_AUTO_UPDATE" && ! -L "$CODEX_AUTO_UPDATE" ]] \
    || fail 'Codex auto-update-version 必须是普通文件。'
  cp -- "$CODEX_AUTO_UPDATE" "$backup/codex-auto-update-version"
  old_codex_auto_update_exists=yes
fi

node_index="$stage/node-index.json"
npm_latest="$stage/npm-latest.json"
echo '解析 Node.js 官方最新 LTS 版本。'
curl --connect-timeout 10 --max-time 30 --retry 3 -fsSL \
  https://nodejs.org/dist/index.json -o "$node_index"
mapfile -t node_metadata < <(json_value "$node_index" node)
[[ ${#node_metadata[@]} == 2 && -n "${node_metadata[0]}" && -n "${node_metadata[1]}" ]] \
  || fail 'Node.js 官方索引缺少最新 LTS 版本或 npm 版本。'
node_version="${node_metadata[0]}"
node_bundled_npm="${node_metadata[1]}"
node_archive="node-v${node_version}-linux-${node_arch}.tar.xz"
curl --connect-timeout 10 --max-time 180 --retry 3 -fsSL \
  "https://nodejs.org/dist/v${node_version}/${node_archive}" -o "$stage/$node_archive"
node_stage="$stage/node"
mkdir -p "$node_stage"
tar --no-same-owner -xJf "$stage/$node_archive" -C "$node_stage" --strip-components=1
[[ -x "$node_stage/bin/node" && -x "$node_stage/bin/npm" ]] || fail 'Node.js 归档缺少 node 或 npm。'
[[ "$("$node_stage/bin/node" --version)" == "v$node_version" ]] || fail 'Node.js 归档版本校验失败。'

echo "解析 npm registry latest（Node.js LTS 归档自带 npm $node_bundled_npm）。"
curl --connect-timeout 10 --max-time 30 --retry 3 -fsSL \
  https://registry.npmjs.org/npm/latest -o "$npm_latest"
mapfile -t npm_metadata < <(json_value "$npm_latest" npm)
[[ ${#npm_metadata[@]} == 2 ]] || fail 'npm registry latest 元数据读取失败。'
npm_version="${npm_metadata[0]}"
npm_engine="${npm_metadata[1]}"
check_node_engine "$node_version" "$npm_engine"
env -i HOME=/root PATH="$node_stage/bin:/usr/local/bin:/usr/bin:/bin" \
  npm_config_cache="$stage/npm-root-cache" npm_config_userconfig=/dev/null \
  npm_config_registry=https://registry.npmjs.org/ \
  "$node_stage/bin/npm" install --global --prefix "$node_stage" \
  "npm@$npm_version" --no-audit --no-fund --prefer-online >/dev/null
[[ "$(env -i HOME=/root PATH="$node_stage/bin:/usr/local/bin:/usr/bin:/bin" "$node_stage/bin/npm" --version)" == "$npm_version" ]] \
  || fail '安装后的 npm 与 registry latest 不一致。'

app_stage="$stage/apps"
install -d -o paseo -g paseo -m 0700 "$app_stage"
install -o paseo -g paseo -m 0644 /dev/stdin "$app_stage/package.json" <<EOF
{
  "name": "paseo-debian-runtime",
  "version": "$PACKAGE_VERSION",
  "private": true,
  "dependencies": {
    "@getpaseo/cli": "latest"
  }
}
EOF
run_as_paseo_with_path "$node_stage/bin:/usr/local/bin:/usr/bin:/bin" \
  "$node_stage/bin/npm" install --prefix "$app_stage" --omit=dev --no-audit --no-fund \
  --package-lock=true --prefer-online >"$stage/npm-install.log" 2>&1 || {
    tail -n 80 "$stage/npm-install.log" >&2
    fail 'Paseo CLI 依赖安装失败。'
  }
run_as_paseo_with_path "$node_stage/bin:/usr/local/bin:/usr/bin:/bin" \
  "$node_stage/bin/npm" --prefix "$app_stage" install-scripts ls --json >"$stage/npm-scripts.json"
mapfile -t npm_script_packages < <(python3 - "$stage/npm-scripts.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
seen = set()
for item in data.get("allowScripts", []):
    if any(change.get("change") == "pending" for change in item.get("changes", [])):
        name = item.get("name")
        if name and name not in seen:
            seen.add(name)
            print(name)
PY
)
if [[ ${#npm_script_packages[@]} -gt 0 ]]; then
  allow_scripts=''
  for package in "${npm_script_packages[@]}"; do
    [[ -z "$allow_scripts" ]] || allow_scripts+=','
    allow_scripts+="$package"
  done
  printf 'allow-scripts=%s\n' "$allow_scripts" > "$app_stage/.npmrc"
  chown paseo:paseo "$app_stage/.npmrc"
  run_as_paseo_with_path "$node_stage/bin:/usr/local/bin:/usr/bin:/bin" \
    "$node_stage/bin/npm" rebuild --prefix "$app_stage" --omit=dev --no-audit --no-fund \
    >"$stage/npm-rebuild.log" 2>&1 || {
      tail -n 80 "$stage/npm-rebuild.log" >&2
      fail 'Paseo CLI native 依赖重建失败。'
    }
  rm -f -- "$app_stage/.npmrc"
fi
[[ -x "$app_stage/node_modules/.bin/paseo" ]] || fail '最新版依赖中缺少 Paseo CLI。'
[[ ! -e "$app_stage/node_modules/@openai/codex" ]] || fail 'Paseo 依赖树意外包含 @openai/codex。'
if grep -Fq '"@openai/codex"' "$app_stage/package.json" "$app_stage/package-lock.json"; then
  fail 'Paseo manifest 或 lockfile 意外声明 @openai/codex。'
fi
read_lock_metadata "$app_stage/package-lock.json" || fail 'Paseo lockfile 校验失败。'
paseo_version="$(run_as_paseo_with_path "$node_stage/bin:$app_stage/node_modules/.bin:/usr/local/bin:/usr/bin:/bin" \
  "$app_stage/node_modules/.bin/paseo" --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1)"
[[ "$paseo_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail '无法读取最新版 Paseo CLI 版本。'
chown -R root:root "$app_stage"
chmod -R u+rwX,go+rX,go-w "$app_stage"
chown -R root:root "$node_stage"
chmod -R u+rwX,go+rX,go-w "$node_stage"

echo '运行 Astral 官方安装器准备 uv 当前稳定版本。'
curl --connect-timeout 10 --max-time 60 --retry 3 -fsSL \
  https://astral.sh/uv/install.sh -o "$stage/uv-install.sh"
uv_stage="$stage/uv"
install -d -o root -g root -m 0755 "$uv_stage"
env -i HOME=/root PATH=/usr/local/bin:/usr/bin:/bin TMPDIR="$stage" \
  UV_INSTALL_DIR="$uv_stage" UV_NO_MODIFY_PATH=1 INSTALLER_PRINT_QUIET=1 \
  /bin/sh "$stage/uv-install.sh"
[[ -x "$uv_stage/uv" && -x "$uv_stage/uvx" ]] || fail 'uv 官方安装器未安装 uv 或 uvx。'
uv_version="$("$uv_stage/uv" --version | awk 'NR == 1 { print $2 }')"
[[ "$uv_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail '无法读取 uv 官方安装结果版本。'
chown -R root:root "$uv_stage"
chmod -R u+rwX,go+rX,go-w "$uv_stage"

codex_installer="$stage/codex-install.sh"
echo '下载并校验 OpenAI 官方 Codex standalone 安装器。'
curl --connect-timeout 10 --max-time 60 --retry 3 -fsSL \
  https://chatgpt.com/codex/install.sh -o "$codex_installer"
grep -Fq 'releases.openai.com/codex' "$codex_installer" || fail '下载的 Codex 安装器不是 OpenAI 官方安装器。'
chmod 0755 "$codex_installer"

run_as_paseo "$APPS_ROOT/node_modules/.bin/paseo" daemon config get --home "$PASEO_HOME" >/dev/null
echo 'Node.js、npm、Paseo 和 uv 已准备并校验；现在停止 Paseo 服务。'
if ! systemctl stop paseo.service; then
  fail '无法停止 Paseo 服务；未修改现有运行时。'
fi
if systemctl is-active --quiet paseo.service; then
  fail 'Paseo 服务停止命令已返回，但服务仍处于活动状态。'
fi
transaction_started=yes
echo '停服确认通过，开始安装 Codex standalone。'
run_as_paseo /usr/bin/env CODEX_HOME="$CODEX_HOME" CODEX_INSTALL_DIR=/srv/paseo/tools/bin \
  CODEX_RELEASE=latest CODEX_NON_INTERACTIVE=1 /bin/sh "$codex_installer"
[[ -x "$CODEX_BIN" ]] || fail 'Codex standalone 更新后缺少管理链接。'
codex_output="$(run_as_paseo "$CODEX_BIN" --version)"
codex_version="$(printf '%s\n' "$codex_output" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1)"
[[ "$codex_output" == codex-cli\ * && "$codex_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail '无法读取 Codex standalone 版本。'
codex_target="$(readlink -f "$CODEX_BIN")"
[[ "$codex_target" == "$CODEX_HOME/packages/standalone/"* ]] || fail 'Codex 管理链接未指向官方 standalone 布局。'
run_as_paseo "$CODEX_BIN" --strict-config --help >/dev/null
run_as_paseo "$CODEX_BIN" app-server --help >/dev/null

cp -- "$INSTALL_STATE" "$backup/install-complete"
chown root:root "$backup/install-complete"
chmod 0644 "$backup/install-complete"
mv -- "$NODE_ROOT" "$backup/node"
mv -- "$node_stage" "$NODE_ROOT"
mv -- "$APPS_ROOT/node_modules" "$backup/apps-node_modules"
mv -- "$APPS_ROOT/package.json" "$backup/apps-package.json"
mv -- "$APPS_ROOT/package-lock.json" "$backup/apps-package-lock.json"
mv -- "$app_stage/node_modules" "$APPS_ROOT/node_modules"
mv -- "$app_stage/package.json" "$APPS_ROOT/package.json"
mv -- "$app_stage/package-lock.json" "$APPS_ROOT/package-lock.json"
mv -- "$UV_ROOT/uv" "$backup/uv"
mv -- "$UV_ROOT/uvx" "$backup/uvx"
mv -- "$uv_stage/uv" "$UV_ROOT/uv"
mv -- "$uv_stage/uvx" "$UV_ROOT/uvx"

[[ "$(run_as_paseo "$NODE_ROOT/bin/node" --version)" == "v$node_version" ]] || fail '更新后的 Node.js 版本校验失败。'
[[ "$(run_as_paseo "$NODE_ROOT/bin/npm" --version)" == "$npm_version" ]] || fail '更新后的 npm 版本校验失败。'
[[ "$(run_as_paseo "$UV_ROOT/uv" --version)" == "uv $uv_version "* ]] || fail '更新后的 uv 版本校验失败。'
systemd-analyze verify "$SERVICE_UNIT" >/dev/null
run_as_paseo "$APPS_ROOT/node_modules/.bin/paseo" daemon config get --home "$PASEO_HOME" >/dev/null
systemctl daemon-reload
if [[ "$service_was_active" == yes ]]; then
  systemctl start paseo.service
  systemctl is-active --quiet paseo.service || fail '更新后的 Paseo 服务未进入 active 状态。'
  health_json="$stage/health.json"
  curl --noproxy '*' --connect-timeout 5 --max-time 15 --retry-max-time 45 -fsS \
    --retry 10 --retry-delay 1 --retry-connrefused http://127.0.0.1:6767/api/health \
    -o "$health_json" 2>"$stage/health-curl.log" || fail '更新后的本机 health 请求失败。'
  python3 - "$health_json" <<'PY'
import json
import sys
json.load(open(sys.argv[1], encoding="utf-8"))
PY
  run_as_paseo "$NODE_ROOT/bin/node" "$PASEO_KIT/lib/relay-check.mjs" \
    || fail '更新后的 Relay TLS/E2EE 状态请求失败；正在回滚运行时。'
fi
verify_protected_files || fail '更新过程修改了受保护的配置、密钥或 systemd 文件。'
[[ "$(stat -c '%d:%i' "$PROJECT_ROOT")" == "$project_identity_before" ]] || fail '项目根目录发生变化。'
[[ "$(stat -c '%d:%i' "$WORKTREE_ROOT")" == "$worktree_identity_before" ]] || fail '工作区根目录发生变化。'
[[ "$(stat -c '%u:%g:%a' "$PROJECT_ROOT")" == "$project_metadata_before" ]] || fail '项目根目录权限发生变化。'
[[ "$(stat -c '%u:%g:%a' "$WORKTREE_ROOT")" == "$worktree_metadata_before" ]] || fail '工作区根目录权限发生变化。'
if [[ "$service_was_active" == no ]]; then
  systemctl stop paseo.service
fi

install -o root -g root -m 0644 /dev/stdin "$INSTALL_STATE.update" <<EOF
package=$PACKAGE_ID
node=$node_version
npm=$npm_version
paseo=$paseo_version
codex=$codex_version
uv=$uv_version
node_source=https://nodejs.org/dist/v$node_version/$node_archive
npm_source=https://registry.npmjs.org/npm/-/npm-$npm_version.tgz
paseo_source=https://registry.npmjs.org/@getpaseo/cli
codex_source=https://chatgpt.com/codex/install.sh
codex_home=$CODEX_HOME
codex_bin=$CODEX_BIN
uv_source=https://astral.sh/uv/install.sh
native_packages=$native_packages
EOF
mv -f -- "$INSTALL_STATE.update" "$INSTALL_STATE"
verify_protected_files || fail '最终受保护文件检查失败。'
if [[ "$service_was_active" == yes ]]; then
  systemctl is-active --quiet paseo.service || fail '更新后的服务状态检查失败。'
else
  systemctl is-active --quiet paseo.service && fail '更新前停止的服务未保持停止状态。'
fi
update_succeeded=yes
