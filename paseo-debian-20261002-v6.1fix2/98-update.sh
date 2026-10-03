#!/usr/bin/env bash
#
# v6.1fix2 运行时组件更新脚本。
#
# 直接运行本脚本会从官方源把 Node.js、npm、Paseo CLI、Codex CLI 和 uv
# 强制更新到当前最新版；它不会执行
# 01-install.sh、02-configure.sh 或 --force，也不会重建 Paseo 配置。
# /srv/proj 中的项目、/srv/paseo/worktrees 中的工作区、模型配置、API key、
# systemd unit 和其他用户数据都会保留，更新后仍可看到原来的 project 和 workspace。
# 脚本通过 curl | sudo bash 运行，
# 不读取 /srv/paseo/deploy-kit 中的任何 paseo-debian-* 工具包。
#
# 脚本先在 /srv/paseo/cache/tmp 中下载并校验 Node/npm、Paseo 和 uv，且在服务
# 仍运行时完成 Codex 官方安装；全部准备完成后才停止服务并替换受管理的运行时
# 目录。替换或健康检查失败时会恢复旧运行时和 Codex 当前链接；旧的项目与工作区
# 从未作为更新对象处理。
set -Eeuo pipefail
umask 022

readonly EXPECTED_RELEASE='paseo-debian-20261002-v6.1fix2'
readonly PACKAGE_VERSION='2026.10.2-v6.1fix2'
readonly PASEO_ROOT='/srv/paseo/runtime'
readonly APPS_ROOT="$PASEO_ROOT/apps"
readonly NODE_ROOT="$PASEO_ROOT/node"
readonly UV_ROOT="$PASEO_ROOT/uv/bin"
readonly CODEX_HOME='/srv/paseo/.codex'
readonly CODEX_BIN='/srv/paseo/tools/bin/codex'
readonly CODEX_AUTO_UPDATE="$CODEX_HOME/packages/standalone/auto-update-version"
readonly PASEO_HOME='/srv/paseo/.paseo'
readonly PASEO_ETC='/etc/paseo'
readonly SERVICE_UNIT='/etc/systemd/system/paseo.service'
readonly CACHE_ROOT='/srv/paseo/cache'
readonly CACHE_TMP="$CACHE_ROOT/tmp"
readonly LOCK_PATH='/run/lock/paseo-v6.1fix2-update.lock'
readonly INSTALL_STATE="$PASEO_ROOT/.install-complete"
readonly PROJECT_ROOT='/srv/proj'
readonly WORKTREE_ROOT='/srv/paseo/worktrees'
readonly RUNTIME_PATH="$APPS_ROOT/node_modules/.bin:$NODE_ROOT/bin:$UV_ROOT:/srv/paseo/tools/bin:/srv/paseo/tools/cargo/bin:/srv/paseo/tools/go/bin:/usr/local/bin:/usr/bin:/bin"

stage=''
backup=''
transaction_started=no
update_succeeded=no
service_was_active=no
old_codex_link_exists=no
old_codex_link_target=''
old_codex_link_owner=''
old_codex_current_exists=no
old_codex_current_target=''
old_codex_current_owner=''
old_codex_auto_update_exists=no
codex_changed=no
preserve_stage=no

fail() {
  echo "更新失败：$*" >&2
  return 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "找不到命令：$1"
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
    CODEX_HOME="$CODEX_HOME" PASEO_HOME="$PASEO_HOME" \
    TMPDIR="$CACHE_TMP" XDG_CACHE_HOME="$CACHE_ROOT" \
    npm_config_cache="$CACHE_ROOT/npm-paseo" \
    npm_config_prefix=/srv/paseo/tools \
    npm_config_userconfig=/dev/null \
    npm_config_registry=https://registry.npmjs.org/ \
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
data = json.load(open(path, encoding='utf-8'))
if expression == 'node':
    for item in data:
        version = item.get('version', '')
        if (
            item.get('lts') is False
            and item.get('security') is not True
            and re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', version)
        ):
            print(version[1:])
            print(item.get('npm', ''))
            break
    else:
        raise SystemExit('Node.js Current 正式发行版未找到。')
elif expression == 'npm':
    version = data.get('version', '')
    engines = data.get('engines', {}).get('node', '')
    integrity = data.get('dist', {}).get('integrity', '')
    if (
        not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version)
        or not engines
        or not integrity.startswith('sha512-')
    ):
        raise SystemExit('npm registry latest 元数据不完整。')
    print(version)
    print(engines)
    print(integrity)
elif expression == 'uv':
    for item in data:
        if not item.get('draft') and not item.get('prerelease'):
            tag = item.get('tag_name', '')
            if re.fullmatch(r'v?[0-9]+\.[0-9]+\.[0-9]+', tag):
                print(tag.lstrip('v'))
                print(tag)
                break
    else:
        raise SystemExit('uv 正式发行版未找到。')
else:
    raise SystemExit(f'未知的版本元数据类型：{expression}')
PY
}

check_node_engine() {
  python3 - "$1" "$2" <<'PY'
import re
import sys

node, expression = sys.argv[1:]
node_parts = tuple(map(int, node.split('.')))


def version(value):
    match = re.fullmatch(r'v?(\d+)(?:\.(\d+))?(?:\.(\d+))?', value.strip())
    if not match:
        return None
    return tuple(int(part or 0) for part in match.groups())


def satisfies_clause(clause):
    clause = clause.strip()
    if not clause or clause in ('*', 'x', 'X'):
        return True
    tokens = clause.replace(',', ' ').split()
    for token in tokens:
        if token.startswith('^'):
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
        if token.startswith('~'):
            base = version(token[1:])
            if base is None or not (node_parts >= base and node_parts < (base[0], base[1] + 1, 0)):
                return False
            continue
        match = re.match(r'^(>=|<=|>|<|=)?(.*)$', token)
        op, raw = match.groups()
        base = version(raw)
        if base is None:
            wildcard = re.fullmatch(
                r'(\d+|x|X|\*)(?:\.(\d+|x|X|\*))?(?:\.(\d+|x|X|\*))?',
                raw,
            )
            if not wildcard:
                return False
            for actual, expected in zip(node_parts, wildcard.groups()):
                if expected is None or expected.lower() in ('x', '*'):
                    break
                if actual != int(expected):
                    return False
            continue
        if op == '>=' and node_parts < base:
            return False
        if op == '<=' and node_parts > base:
            return False
        if op == '>' and node_parts <= base:
            return False
        if op == '<' and node_parts >= base:
            return False
        if op in (None, '=') and node_parts != base:
            return False
    return True


if not any(satisfies_clause(clause) for clause in expression.split('||')):
    raise SystemExit(f'Node.js v{node} 不满足 npm@latest 的 engines.node: {expression}')
PY
}

validate_manifest() {
  EXPECTED_PACKAGE_VERSION="$PACKAGE_VERSION" python3 - "$1" <<'PY'
import json
import os
import sys

path = sys.argv[1]
data = json.load(open(path, encoding='utf-8'))
if data.get('version') != os.environ['EXPECTED_PACKAGE_VERSION']:
    raise SystemExit('apps/package.json 不是 v6.1fix2 manifest。')
if data.get('dependencies') != {'@getpaseo/cli': 'latest'}:
    raise SystemExit('apps/package.json 依赖声明已被修改；为避免覆盖自定义内容，更新停止。')
PY
}

read_lock_metadata() {
  mapfile -t lock_metadata < <(python3 - "$1" <<'PY'
import json
import sys

path = sys.argv[1]
lock = json.load(open(path, encoding='utf-8'))
root = lock.get('packages', {}).get('')
entry = lock.get('packages', {}).get('node_modules/@getpaseo/cli', {})
if not isinstance(root, dict) or root.get('dependencies') != {'@getpaseo/cli': 'latest'}:
    raise SystemExit('Paseo lockfile 根依赖声明不正确。')
integrity = entry.get('integrity', '')
if not integrity.startswith('sha512-'):
    raise SystemExit('Paseo lockfile 缺少 registry integrity。')
items = []
for name, item in lock.get('packages', {}).items():
    if not name.startswith('node_modules/') or not item.get('hasInstallScript'):
        continue
    package = name.removeprefix('node_modules/')
    items.append(f"{package}@{item.get('version', '')}")
if not items:
    raise SystemExit('Paseo 依赖树没有可验证的 native/install-script 包。')
print(integrity)
print(','.join(sorted(items)))
PY
)
  [[ ${#lock_metadata[@]} == 2 ]] || return 1
  paseo_integrity="${lock_metadata[0]}"
  native_packages="${lock_metadata[1]}"
}

snapshot_protected_files() {
  : > "$protected_snapshot"
  : > "$protected_metadata_snapshot"
  local path
  for path in "${protected_files[@]}"; do
    if [[ -f "$path" ]]; then
      sha256sum -- "$path" >> "$protected_snapshot"
      printf '%s\t%s\n' "$path" "$(stat -c '%u:%g:%a' -- "$path")" \
        >> "$protected_metadata_snapshot"
    else
      printf '%s\tABSENT\n' "$path" >> "$protected_metadata_snapshot"
    fi
  done
}

verify_protected_files() {
  sha256sum --strict --check "$protected_snapshot" >/dev/null
  while IFS=$'\t' read -r path expected; do
    if [[ "$expected" == ABSENT ]]; then
      [[ ! -e "$path" && ! -L "$path" ]] || return 1
    else
      [[ -f "$path" ]] || return 1
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
  if [[ "$old_codex_link_exists" == yes ]]; then
    rm -f -- "$CODEX_BIN"
    ln -s -- "$old_codex_link_target" "$CODEX_BIN" || restore_status=1
    chown -h -- "$old_codex_link_owner" "$CODEX_BIN" || restore_status=1
  else
    rm -f -- "$CODEX_BIN"
  fi
  if [[ "$old_codex_current_exists" == yes ]]; then
    rm -f -- "$CODEX_HOME/packages/standalone/current"
    ln -s -- "$old_codex_current_target" "$CODEX_HOME/packages/standalone/current" \
      || restore_status=1
    chown -h -- "$old_codex_current_owner" \
      "$CODEX_HOME/packages/standalone/current" || restore_status=1
  fi
  if [[ "$old_codex_auto_update_exists" == yes ]]; then
    restore_item "$CODEX_AUTO_UPDATE" "$backup/codex-auto-update-version" \
      || restore_status=1
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
      echo '旧运行时恢复失败；请勿再次运行更新，先检查 systemctl status paseo.service。' >&2
      preserve_stage=yes
      status=1
    else
      echo '旧运行时已恢复。' >&2
    fi
  elif [[ "$codex_changed" == yes && "$update_succeeded" != yes ]]; then
    echo '更新未完成，正在恢复更新前的 Codex 链接。' >&2
    if ! restore_codex_state; then
      echo 'Codex 链接恢复失败；请勿再次运行更新，先检查 Codex standalone 状态。' >&2
      preserve_stage=yes
      status=1
    else
      echo '更新前的 Codex 链接已恢复。' >&2
    fi
  fi
  if [[ "$preserve_stage" == yes ]]; then
    echo "回滚备份已保留在：$stage" >&2
  elif [[ -n "$stage" && -d "$stage" ]]; then
    rm -rf -- "$stage"
  fi
  rm -f -- "$INSTALL_STATE.update"
  if [[ "$status" == 0 && "$update_succeeded" == yes ]]; then
    echo 'UPDATE_OK：Node.js、npm、Paseo CLI、Codex CLI 和 uv 已更新，项目与工作区保持不变。'
  fi
  exit "$status"
}
trap on_exit EXIT

require_root() {
  [[ $EUID == 0 ]] || fail '请以 root 或 sudo bash 执行。'
}

require_root
for command in awk cat chmod chown cp curl cut find flock grep head id install ln mktemp mv python3 readlink rm runuser sha256sum sort stat systemctl systemd-analyze tail tar uname xz; do
  require_command "$command"
done

[[ -r /etc/os-release ]] || fail '无法读取 /etc/os-release。'
# shellcheck disable=SC1091
source /etc/os-release
[[ "$ID" == debian && "${VERSION_CODENAME:-}" =~ ^(bookworm|trixie)$ ]] \
  || fail "仅支持 Debian 12 (bookworm) 或 Debian 13 (trixie)。检测到：${PRETTY_NAME:-unknown}"

case "$(uname -m)" in
  x86_64) node_arch=x64; uv_arch=x86_64 ;;
  aarch64) node_arch=arm64; uv_arch=aarch64 ;;
  *) fail '仅支持 amd64 (x86_64) 或 arm64 (aarch64)。' ;;
esac

[[ -d "$PASEO_ROOT" && ! -L "$PASEO_ROOT" ]] || fail "运行时目录不存在或不是普通目录：$PASEO_ROOT"
[[ -d "$APPS_ROOT" && ! -L "$APPS_ROOT" ]] || fail "应用目录不存在或不是普通目录：$APPS_ROOT"
[[ -d "$NODE_ROOT" && ! -L "$NODE_ROOT" ]] || fail "Node.js 目录不存在或不是普通目录：$NODE_ROOT"
[[ -d "$UV_ROOT" && ! -L "$UV_ROOT" ]] || fail "uv 目录不存在或不是普通目录：$UV_ROOT"
[[ -d "$APPS_ROOT/node_modules" && ! -L "$APPS_ROOT/node_modules" ]] \
  || fail 'Paseo node_modules 目录不存在或不是普通目录。'
[[ -f "$UV_ROOT/uv" && ! -L "$UV_ROOT/uv" \
  && -f "$UV_ROOT/uvx" && ! -L "$UV_ROOT/uvx" ]] \
  || fail 'uv 可执行文件缺失或不是普通文件。'
[[ -d "$PROJECT_ROOT" && ! -L "$PROJECT_ROOT" ]] || fail "项目目录不存在或不是普通目录：$PROJECT_ROOT"
[[ -d "$WORKTREE_ROOT" && ! -L "$WORKTREE_ROOT" ]] || fail "工作区目录不存在或不是普通目录：$WORKTREE_ROOT"
[[ -d "$CODEX_HOME" && ! -L "$CODEX_HOME" ]] || fail "Codex 目录不存在或不是普通目录：$CODEX_HOME"
[[ -d "$PASEO_HOME" && ! -L "$PASEO_HOME" ]] || fail "Paseo 配置目录不存在或不是普通目录：$PASEO_HOME"
[[ -d "$PASEO_ETC" && ! -L "$PASEO_ETC" ]] || fail "Paseo 环境目录不存在或不是普通目录：$PASEO_ETC"
[[ -d "$CACHE_ROOT" && ! -L "$CACHE_ROOT" ]] || fail "缓存目录不存在或不是普通目录：$CACHE_ROOT"
[[ -d "$CACHE_TMP" && ! -L "$CACHE_TMP" ]] || fail "缓存临时目录不存在或不是普通目录：$CACHE_TMP"
[[ "$(stat -c '%d' "$CACHE_TMP")" == "$(stat -c '%d' "$PASEO_ROOT")" ]] \
  || fail '缓存临时目录与运行时不在同一文件系统；为保证可回滚更新而停止。'
[[ -f "$INSTALL_STATE" ]] || fail "缺少安装记录：$INSTALL_STATE"
[[ "$(stat -c '%u:%g:%a' "$INSTALL_STATE")" == '0:0:644' ]] \
  || fail '安装记录必须为 root:root、0644。'
[[ -f "$PASEO_ETC/.configured" ]] || fail '缺少完成配置标记；请先完成 v6.1fix2 配置。'
[[ -f "$APPS_ROOT/package.json" && -f "$APPS_ROOT/package-lock.json" ]] || fail 'Paseo manifest 或 lockfile 缺失。'
[[ -f "$PASEO_HOME/config.json" && -f "$CODEX_HOME/config.toml" ]] || fail 'Paseo 或 Codex 配置缺失。'
[[ -f "$PASEO_ETC/runtime.env" && -f "$PASEO_ETC/hahaapi.env" ]] || fail '运行时环境或 HahaAPI key 文件缺失。'
[[ -f "$SERVICE_UNIT" ]] || fail "systemd unit 缺失：$SERVICE_UNIT"
[[ -x "$CODEX_BIN" && -L "$CODEX_BIN" ]] || fail "Codex 管理链接缺失：$CODEX_BIN"
[[ -L "$CODEX_HOME/packages/standalone/current" ]] || fail 'Codex standalone current 链接缺失。'
[[ "$(stat -c '%u:%g:%a' "$PASEO_HOME/config.json")" == "$(id -u paseo):$(id -g paseo):600" ]] \
  || fail 'Paseo 配置必须由 paseo 用户持有且权限为 0600。'
[[ "$(stat -c '%u:%g:%a' "$CODEX_HOME/config.toml")" == "$(id -u paseo):$(id -g paseo):600" ]] \
  || fail 'Codex 配置必须由 paseo 用户持有且权限为 0600。'
[[ "$(stat -c '%u:%g:%a' "$PASEO_ETC/runtime.env")" == '0:0:644' ]] \
  || fail 'runtime.env 必须为 root:root、0644。'
[[ "$(stat -c '%u:%g:%a' "$PASEO_ETC/hahaapi.env")" == '0:0:600' ]] \
  || fail 'HahaAPI key 文件必须为 root:root、0600。'
if [[ -e "$PASEO_ETC/backapi.env" ]]; then
  [[ -f "$PASEO_ETC/backapi.env" \
    && "$(stat -c '%u:%g:%a' "$PASEO_ETC/backapi.env")" == '0:0:600' ]] \
    || fail 'BackAPI key 文件必须为 root:root、0600。'
  [[ -f "$APPS_ROOT/backapi-codex-wrapper" \
    && -f /etc/systemd/system/paseo.service.d/10-backapi.conf ]] \
    || fail 'BackAPI key 存在但 wrapper 或 systemd drop-in 缺失。'
else
  [[ ! -e "$APPS_ROOT/backapi-codex-wrapper" \
    && ! -L "$APPS_ROOT/backapi-codex-wrapper" \
    && ! -e /etc/systemd/system/paseo.service.d/10-backapi.conf \
    && ! -L /etc/systemd/system/paseo.service.d/10-backapi.conf ]] \
    || fail 'BackAPI wrapper 或 drop-in 存在但 key 文件缺失。'
fi

[[ "$(state_value package)" == "$EXPECTED_RELEASE" ]] \
  || fail "安装记录不是 $EXPECTED_RELEASE；未升级其他版本。"
[[ "$(state_value codex_home)" == "$CODEX_HOME" \
  && "$(state_value codex_bin)" == "$CODEX_BIN" ]] \
  || fail '安装记录中的 Codex 路径不是 v6.1fix2 托管布局。'
validate_manifest "$APPS_ROOT/package.json"

service_was_active=no
if systemctl is-active --quiet paseo.service; then
  service_was_active=yes
fi

cache_owner="$(stat -c '%u:%g %a' "$CACHE_ROOT")"
cache_tmp_owner="$(stat -c '%u:%g %a' "$CACHE_TMP")"
paseo_uid="$(id -u paseo)"
paseo_gid="$(id -g paseo)"
[[ "$cache_owner" == "$paseo_uid:$paseo_gid 700" ]] \
  || fail '缓存目录必须保持 paseo 用户、0700 权限；未开始更新。'
[[ "$cache_tmp_owner" == "$paseo_uid:$paseo_gid 700" ]] \
  || fail '缓存临时目录必须保持 paseo 用户、0700 权限；未开始更新。'
for cache_name in npm-paseo pip uv gomod go-build ms-playwright; do
  cache_path="$CACHE_ROOT/$cache_name"
  [[ -d "$cache_path" && ! -L "$cache_path" ]] \
    || fail "缓存子目录不存在或不是普通目录：$cache_path"
  [[ "$(stat -c '%u:%g %a' "$cache_path")" == "$paseo_uid:$paseo_gid 700" ]] \
    || fail "缓存子目录必须保持 paseo 用户、0700 权限：$cache_path"
done
[[ -d /run/lock && ! -L /run/lock ]] || fail '系统锁目录 /run/lock 不可用。'
[[ ! -L "$LOCK_PATH" ]] || fail '更新锁路径不允许是符号链接。'
exec 9>>"$LOCK_PATH"
chmod 0600 "$LOCK_PATH"
flock -n 9 || fail '已有另一个 v6.1fix2 更新正在执行。'

stage="$(mktemp -d "$CACHE_TMP/paseo-update.XXXXXX")"
chown paseo:paseo "$stage"
chmod 0700 "$stage"
backup="$stage/backup"
install -d -o root -g root -m 0700 "$backup"
protected_snapshot="$stage/protected.sha256"
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
old_node_version="$(state_value node)"
old_npm_version="$(state_value npm)"
old_paseo_version="$(state_value paseo)"
old_codex_version="$(state_value codex)"
old_uv_version="$(state_value uv)"
for state_key in node npm paseo codex uv; do
  [[ -n "$(state_value "$state_key")" ]] \
    || fail "安装记录缺少组件版本：$state_key"
done

[[ -x "$NODE_ROOT/bin/node" && -x "$NODE_ROOT/bin/npm" \
  && -x "$APPS_ROOT/node_modules/.bin/paseo" \
  && -x "$UV_ROOT/uv" && -x "$UV_ROOT/uvx" ]] \
  || fail '已安装运行时缺少 Node.js、npm、Paseo CLI 或 uv 可执行文件。'
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

old_codex_link_target="$(readlink "$CODEX_BIN")"
old_codex_link_exists=yes
old_codex_link_owner="$(stat -c '%u:%g' "$CODEX_BIN")"
old_codex_current_target="$(readlink "$CODEX_HOME/packages/standalone/current")"
old_codex_current_exists=yes
old_codex_current_owner="$(stat -c '%u:%g' "$CODEX_HOME/packages/standalone/current")"
if [[ -f "$CODEX_AUTO_UPDATE" ]]; then
  cp -a -- "$CODEX_AUTO_UPDATE" "$backup/codex-auto-update-version"
  old_codex_auto_update_exists=yes
fi

if [[ "$(readlink -f "$CODEX_BIN")" != "$CODEX_HOME/packages/standalone/"* ]]; then
  fail 'Codex 管理链接未指向官方 standalone 布局。'
fi
old_codex_target="$(readlink -f "$CODEX_BIN")"
old_codex_sha256="$(state_value codex_binary_sha256)"
[[ "$old_codex_sha256" =~ ^[0-9a-f]{64}$ ]] \
  || fail '安装记录缺少有效的旧 Codex SHA256。'
[[ "$(sha256sum "$old_codex_target" | awk '{print $1}')" == "$old_codex_sha256" ]] \
  || fail '当前 Codex 二进制与安装记录不一致。'
current_codex_output="$(run_as_paseo "$CODEX_BIN" --version)"
[[ "$current_codex_output" == "codex-cli $old_codex_version" ]] \
  || fail '当前 Codex CLI 与安装记录不一致。'

node_index="$stage/node-index.json"
npm_latest="$stage/npm-latest.json"
echo '解析 Node.js 官方 Current 版本。'
curl --connect-timeout 10 --max-time 30 --retry 3 -fsSL \
  https://nodejs.org/dist/index.json -o "$node_index"
mapfile -t node_metadata < <(json_value "$node_index" node)
[[ ${#node_metadata[@]} == 2 && -n "${node_metadata[0]}" && -n "${node_metadata[1]}" ]] \
  || fail 'Node.js 官方索引缺少 Current 版本或 npm 版本。'
node_version="${node_metadata[0]}"
node_bundled_npm="${node_metadata[1]}"
node_archive="node-v${node_version}-linux-${node_arch}.tar.xz"
curl --connect-timeout 10 --max-time 180 --retry 3 -fsSL \
  "https://nodejs.org/dist/v${node_version}/${node_archive}" \
  -o "$stage/$node_archive"
curl --connect-timeout 10 --max-time 30 --retry 3 -fsSL \
  "https://nodejs.org/dist/v${node_version}/SHASUMS256.txt" \
  -o "$stage/node-SHASUMS256.txt"
(
  cd "$stage"
  awk -v file="$node_archive" '$2 == file { print; found=1 } END { exit(found ? 0 : 1) }' \
    node-SHASUMS256.txt > node-selected.sha256
  sha256sum --strict --check node-selected.sha256
)
node_sha256="$(awk '{print $1}' "$stage/node-selected.sha256")"
node_stage="$stage/node"
mkdir -p "$node_stage"
tar --no-same-owner -xJf "$stage/$node_archive" -C "$node_stage" --strip-components=1
[[ -x "$node_stage/bin/node" && -x "$node_stage/bin/npm" ]] \
  || fail 'Node.js 官方归档缺少 node 或 npm。'
[[ "$("$node_stage/bin/node" --version)" == "v$node_version" ]] \
  || fail 'Node.js 官方归档版本与索引不一致。'

echo "解析 npm registry latest（Node.js Current 自带 npm $node_bundled_npm）。"
curl --connect-timeout 10 --max-time 30 --retry 3 -fsSL \
  https://registry.npmjs.org/npm/latest -o "$npm_latest"
mapfile -t npm_metadata < <(json_value "$npm_latest" npm)
[[ ${#npm_metadata[@]} == 3 ]] || fail 'npm registry latest 元数据读取失败。'
npm_version="${npm_metadata[0]}"
npm_engine="${npm_metadata[1]}"
npm_integrity="${npm_metadata[2]}"
check_node_engine "$node_version" "$npm_engine"
env -i HOME=/root PATH="$node_stage/bin:/usr/local/bin:/usr/bin:/bin" \
  npm_config_cache="$stage/npm-root-cache" npm_config_userconfig=/dev/null \
  npm_config_registry=https://registry.npmjs.org/ \
  "$node_stage/bin/npm" install --global --prefix "$node_stage" \
  "npm@$npm_version" --no-audit --no-fund --prefer-online >/dev/null
[[ "$(env -i HOME=/root PATH="$node_stage/bin:/usr/local/bin:/usr/bin:/bin" \
  "$node_stage/bin/npm" --version)" == "$npm_version" ]] \
  || fail '安装后的 npm 与 registry latest 不一致。'

app_stage="$stage/apps"
install -d -o paseo -g paseo -m 0700 "$app_stage"
cp -- "$APPS_ROOT/package.json" "$app_stage/package.json"
chown paseo:paseo "$app_stage/package.json"
run_as_paseo_with_path "$node_stage/bin:$node_stage/bin:/usr/local/bin:/usr/bin:/bin" \
  "$node_stage/bin/npm" install --prefix "$app_stage" \
  --omit=dev --no-audit --no-fund --package-lock=true --prefer-online \
  >"$stage/npm-install.log" 2>&1 || {
    tail -n 80 "$stage/npm-install.log" >&2
    fail 'Paseo CLI 依赖安装失败。'
  }
run_as_paseo_with_path "$node_stage/bin:$node_stage/bin:/usr/local/bin:/usr/bin:/bin" \
  "$node_stage/bin/npm" --prefix "$app_stage" install-scripts ls --json \
  >"$stage/npm-scripts.json"
mapfile -t npm_script_packages < <(python3 - "$stage/npm-scripts.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding='utf-8'))
seen = set()
for item in data.get('allowScripts', []):
    if any(change.get('change') == 'pending' for change in item.get('changes', [])):
        name = item.get('name')
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
  run_as_paseo_with_path "$node_stage/bin:$node_stage/bin:/usr/local/bin:/usr/bin:/bin" \
    "$node_stage/bin/npm" rebuild --prefix "$app_stage" \
    --omit=dev --no-audit --no-fund >"$stage/npm-rebuild.log" 2>&1 || {
      tail -n 80 "$stage/npm-rebuild.log" >&2
      fail 'Paseo CLI native 依赖重建失败。'
    }
  rm -f -- "$app_stage/.npmrc"
fi
[[ -x "$app_stage/node_modules/.bin/paseo" ]] || fail '最新版依赖中缺少 Paseo CLI。'
[[ ! -e "$app_stage/node_modules/@openai/codex" ]] || fail 'Paseo npm 依赖树意外包含 @openai/codex。'
if grep -Fq '"@openai/codex"' "$app_stage/package.json" "$app_stage/package-lock.json"; then
  fail 'Paseo manifest 或 lockfile 意外声明 @openai/codex。'
fi
validate_manifest "$app_stage/package.json"
read_lock_metadata "$app_stage/package-lock.json" \
  || fail '最新版 Paseo lockfile 校验失败。'
paseo_version="$(run_as_paseo_with_path "$node_stage/bin:$app_stage/node_modules/.bin:/usr/local/bin:/usr/bin:/bin" \
  "$app_stage/node_modules/.bin/paseo" --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
[[ "$paseo_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail '无法读取最新版 Paseo CLI 版本。'
chown -R root:root "$app_stage"
chmod -R u+rwX,go+rX,go-w "$app_stage"
chown -R root:root "$node_stage"
chmod -R u+rwX,go+rX,go-w "$node_stage"

echo '解析 uv GitHub 正式发行版并校验官方 checksum。'
uv_releases="$stage/uv-releases.json"
curl --connect-timeout 10 --max-time 60 --retry 3 -fsSL \
  -H 'Accept: application/vnd.github+json' \
  'https://api.github.com/repos/astral-sh/uv/releases?per_page=100' \
  -o "$uv_releases"
mapfile -t uv_metadata < <(json_value "$uv_releases" uv)
[[ ${#uv_metadata[@]} == 2 ]] || fail 'uv GitHub release 元数据读取失败。'
uv_version="${uv_metadata[0]}"
uv_tag="${uv_metadata[1]}"
uv_archive="uv-${uv_arch}-unknown-linux-gnu.tar.gz"
curl --connect-timeout 10 --max-time 180 --retry 3 -fsSL \
  "https://github.com/astral-sh/uv/releases/download/${uv_tag}/${uv_archive}" \
  -o "$stage/$uv_archive"
curl --connect-timeout 10 --max-time 30 --retry 3 -fsSL \
  "https://github.com/astral-sh/uv/releases/download/${uv_tag}/sha256.sum" \
  -o "$stage/uv-sha256.sum"
python3 - "$stage/uv-sha256.sum" "$uv_archive" "$stage/uv-selected.sha256" <<'PY'
import re
import sys

source, archive, output = sys.argv[1:]
for line in open(source, encoding='utf-8'):
    parts = line.split()
    if len(parts) >= 2 and parts[1].lstrip('*') == archive and re.fullmatch(r'[0-9a-fA-F]{64}', parts[0]):
        with open(output, 'w', encoding='ascii') as stream:
            stream.write(f'{parts[0]}  {archive}\n')
        break
else:
    raise SystemExit(f'uv checksum 缺少 {archive}')
PY
(cd "$stage" && sha256sum --strict --check uv-selected.sha256)
uv_sha256="$(awk '{print $1}' "$stage/uv-selected.sha256")"
uv_stage="$stage/uv"
mkdir -p "$uv_stage"
tar --no-same-owner -xzf "$stage/$uv_archive" -C "$uv_stage" --strip-components=1
[[ -x "$uv_stage/uv" && -x "$uv_stage/uvx" ]] \
  || fail 'uv 官方归档缺少 uv 或 uvx 可执行文件。'
chown -R root:root "$uv_stage"
chmod -R u+rwX,go+rX,go-w "$uv_stage"

codex_installer="$stage/codex-install.sh"
echo '下载并校验 OpenAI 官方 Codex standalone 安装器。'
curl --connect-timeout 10 --max-time 60 --retry 3 -fsSL \
  https://chatgpt.com/codex/install.sh -o "$codex_installer"
grep -Fq 'releases.openai.com/codex' "$codex_installer" \
  || fail '下载的 Codex 安装器不是当前 OpenAI 官方安装器。'
chmod 0755 "$codex_installer"
codex_installer_sha256="$(sha256sum "$codex_installer" | awk '{print $1}')"

# Codex 安装器在服务仍运行时完成下载和安装；这样进入停机替换阶段时，
# 所有新组件都已经准备好。失败时 EXIT trap 只恢复 Codex 链接，不停服务。
codex_changed=yes
run_as_paseo /usr/bin/env \
  CODEX_HOME="$CODEX_HOME" CODEX_INSTALL_DIR=/srv/paseo/tools/bin \
  CODEX_RELEASE=latest CODEX_NON_INTERACTIVE=1 \
  /bin/sh "$codex_installer"
[[ -x "$CODEX_BIN" ]] || fail 'Codex standalone 更新后缺少管理链接。'
codex_output="$(run_as_paseo "$CODEX_BIN" --version)"
codex_version="$(printf '%s\n' "$codex_output" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1)"
[[ "$codex_output" == codex-cli\ * && "$codex_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail '无法从 Codex standalone 读取正式版本。'
codex_target="$(readlink -f "$CODEX_BIN")"
[[ "$codex_target" == "$CODEX_HOME/packages/standalone/"* ]] \
  || fail 'Codex 管理链接未指向官方 standalone 布局。'
codex_binary_sha256="$(sha256sum "$codex_target" | awk '{print $1}')"
run_as_paseo "$CODEX_BIN" --strict-config --help >/dev/null
run_as_paseo "$CODEX_BIN" app-server --help >/dev/null

old_install_state="$backup/install-complete"
cp -- "$INSTALL_STATE" "$old_install_state"
chown root:root "$old_install_state"
chmod 0644 "$old_install_state"

# 到这里所有新归档和依赖均已准备好；现在才进入短暂停机和可回滚替换阶段。
echo '所有新组件已校验，停止 Paseo 服务并开始可回滚替换。'
transaction_started=yes
systemctl stop paseo.service

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

node_actual="$(run_as_paseo "$NODE_ROOT/bin/node" --version)"
npm_actual="$(run_as_paseo "$NODE_ROOT/bin/npm" --version)"
uv_actual="$(run_as_paseo "$UV_ROOT/uv" --version)"
[[ "$node_actual" == "v$node_version" && "$npm_actual" == "$npm_version" ]] \
  || fail '更新后的 Node.js/npm 版本校验失败。'
[[ "$uv_actual" == "uv $uv_version "* ]] || fail '更新后的 uv 版本校验失败。'

systemd-analyze verify "$SERVICE_UNIT" >/dev/null
run_as_paseo "$APPS_ROOT/node_modules/.bin/paseo" daemon config get \
  --home "$PASEO_HOME" >/dev/null
systemctl start paseo.service
systemctl is-active --quiet paseo.service || fail '更新后的 Paseo 服务未进入 active 状态。'
health_json="$stage/health.json"
curl --noproxy '*' --connect-timeout 5 --max-time 15 --retry-max-time 45 -fsS \
  --retry 10 --retry-delay 1 --retry-connrefused \
  http://127.0.0.1:6767/api/health -o "$health_json"
python3 - "$health_json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding='utf-8') as stream:
    json.load(stream)
PY
verify_protected_files || fail '更新过程修改了受保护的配置、密钥或 systemd 文件。'
[[ "$(stat -c '%d:%i' "$PROJECT_ROOT")" == "$project_identity_before" ]] \
  || fail '项目根目录发生变化，更新停止。'
[[ "$(stat -c '%d:%i' "$WORKTREE_ROOT")" == "$worktree_identity_before" ]] \
  || fail '工作区根目录发生变化，更新停止。'
[[ "$(stat -c '%u:%g:%a' "$PROJECT_ROOT")" == "$project_metadata_before" ]] \
  || fail '项目根目录属主或权限发生变化，更新停止。'
[[ "$(stat -c '%u:%g:%a' "$WORKTREE_ROOT")" == "$worktree_metadata_before" ]] \
  || fail '工作区根目录属主或权限发生变化，更新停止。'

if [[ "$service_was_active" == no ]]; then
  systemctl stop paseo.service
fi

install -o root -g root -m 0644 /dev/stdin "$INSTALL_STATE.update" <<EOF
package=$EXPECTED_RELEASE
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
uv_source=https://github.com/astral-sh/uv/releases/download/$uv_tag/$uv_archive
node_sha256=$node_sha256
npm_integrity=$npm_integrity
paseo_integrity=$paseo_integrity
native_packages=$native_packages
codex_installer_sha256=$codex_installer_sha256
codex_binary_sha256=$codex_binary_sha256
uv_sha256=$uv_sha256
EOF
mv -f -- "$INSTALL_STATE.update" "$INSTALL_STATE"
verify_protected_files
[[ "$(stat -c '%d:%i' "$PROJECT_ROOT")" == "$project_identity_before" ]] || fail '项目根目录最终检查失败。'
[[ "$(stat -c '%d:%i' "$WORKTREE_ROOT")" == "$worktree_identity_before" ]] || fail '工作区根目录最终检查失败。'
[[ "$(stat -c '%u:%g:%a' "$PROJECT_ROOT")" == "$project_metadata_before" ]] \
  || fail '项目根目录最终权限检查失败。'
[[ "$(stat -c '%u:%g:%a' "$WORKTREE_ROOT")" == "$worktree_metadata_before" ]] \
  || fail '工作区根目录最终权限检查失败。'
if [[ "$service_was_active" == yes ]]; then
  systemctl is-active --quiet paseo.service || fail '更新后的服务状态检查失败。'
else
  systemctl is-active --quiet paseo.service && fail '更新前停止的服务未保持停止状态。'
fi

update_succeeded=yes
echo "已完成：Node.js $old_node_version -> $node_version；npm $old_npm_version -> $npm_version；Paseo CLI $old_paseo_version -> $paseo_version；Codex CLI $old_codex_version -> $codex_version；uv $old_uv_version -> $uv_version。"


