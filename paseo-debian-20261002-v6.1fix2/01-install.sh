#!/usr/bin/env bash
# Install the current official runtime on a clean Debian host.
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat <<'USAGE'
用法：
  sudo bash 01-install.sh
  sudo bash 01-install.sh --force

每次安装都会从官方当前稳定元数据解析 Node.js Current、npm registry latest、
Paseo CLI、OpenAI Codex standalone 和 uv。--force 停止并重建 v6.1fix2 托管运行时、
配置、密钥、Codex standalone 状态和 systemd unit；保留用户项目、worktrees、
非托管工具和缓存。
USAGE
}

force=false
case "${1:-}" in
  '') ;;
  --force) force=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 64; }

require_root
umask 022

[[ -r /etc/os-release ]] || { echo '无法读取 /etc/os-release。' >&2; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
[[ "$ID" == debian && "${VERSION_CODENAME:-}" =~ ^(bookworm|trixie)$ ]] || {
  echo "仅支持 Debian 12 (bookworm) 或 Debian 13 (trixie)。检测到：${PRETTY_NAME:-unknown}" >&2
  exit 1
}

case "$(uname -m)" in
  x86_64) node_arch=x64; uv_arch=x86_64 ;;
  aarch64) node_arch=arm64; uv_arch=aarch64 ;;
  *) echo '仅支持 amd64 (x86_64) 或 arm64 (aarch64)。' >&2; exit 1 ;;
esac

for command in apt-get cut getent id install mktemp rm uname; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "找不到 $command，无法安装 v6.1fix2。" >&2
    exit 1
  }
done

if id paseo >/dev/null 2>&1; then
  [[ "$(getent passwd paseo | cut -d: -f6)" == /srv/paseo ]] || {
    echo '已有 paseo 账户但 home 不是 /srv/paseo；已停止。' >&2
    exit 1
  }
fi

managed_paths=(
  "$PASEO_ROOT"
  "$PASEO_ETC"
  /etc/systemd/system/paseo.service
  /etc/systemd/system/paseo.service.d
  "$PASEO_CODEX_HOME"
  "$PASEO_CODEX_BIN"
  /srv/paseo/.paseo
  /srv/paseo/.profile
)
if [[ "$force" != true ]]; then
  for path in "${managed_paths[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
      echo "检测到已有 v6.1fix2 托管路径：$path；如需全新覆盖，请使用 --force。" >&2
      exit 1
    fi
  done
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl xz-utils unzip zip bzip2 gzip openssl \
  python3 python3-venv build-essential pkg-config libssl-dev libffi-dev \
  git git-lfs ripgrep jq tmux rsync nftables iproute2 procps util-linux

for command in awk cat chown curl find grep head mv python3 readlink runuser sha256sum stat systemctl tar; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "安装依赖后仍找不到 $command，无法安装 v6.1fix2。" >&2
    exit 1
  }
done

if [[ "$force" == true ]]; then
  systemctl disable --now paseo.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/paseo.service
  rm -rf /etc/systemd/system/paseo.service.d
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed paseo.service >/dev/null 2>&1 || true

  rm -rf -- "$PASEO_ROOT" "$PASEO_ETC" "$PASEO_CODEX_HOME" /srv/paseo/.paseo /srv/paseo/.profile
  rm -f -- "$PASEO_CODEX_BIN"
fi

if ! id paseo >/dev/null 2>&1; then
  useradd --create-home --home-dir /srv/paseo --shell /bin/bash --user-group paseo
fi

install -d -o paseo -g paseo -m 0700 /srv/paseo
for directory in .codex .paseo worktrees tools tools/bin; do
  install -d -o paseo -g paseo -m 0700 "/srv/paseo/$directory"
done
if [[ ! -d /srv/proj ]]; then
  install -d -o paseo -g paseo -m 0700 /srv/proj
else
  [[ -x /srv/proj ]] || {
    echo '/srv/proj 对 paseo 用户不可进入；请调整项目根目录权限后重试。' >&2
    exit 1
  }
fi
ensure_cache_layout
install -d -o root -g root -m 0755 "$PASEO_ROOT" "$PASEO_ROOT/apps" "$PASEO_ROOT/uv/bin"

install_tmp="$(mktemp -d "$PASEO_CACHE_ROOT/tmp/paseo-install.XXXXXX")"
chown paseo:paseo "$install_tmp"
cleanup() {
  local status=$?
  rm -f -- "$PASEO_ROOT/apps/.npmrc"
  rm -rf -- "$install_tmp"
  return "$status"
}
trap cleanup EXIT

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
        if item.get('lts') is False and item.get('security') is not True and re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', version):
            print(version[1:])
            print(item.get('npm', ''))
            break
    else:
        raise SystemExit('Node.js Current 正式发行版未找到。')
elif expression == 'npm':
    version = data.get('version', '')
    engines = data.get('engines', {}).get('node', '')
    integrity = data.get('dist', {}).get('integrity', '')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not engines or not integrity.startswith('sha512-'):
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
            # Handle simple wildcard ranges such as 26.x.
            wildcard = re.fullmatch(r'(\d+|x|X|\*)(?:\.(\d+|x|X|\*))?(?:\.(\d+|x|X|\*))?', raw)
            if not wildcard:
                return False
            values = wildcard.groups()
            for actual, expected in zip(node_parts, values):
                if expected is None or expected.lower() == 'x' or expected == '*':
                    break
                if actual != int(expected):
                    return False
            continue
        if op == '>=' and node_parts < base: return False
        if op == '<=' and node_parts > base: return False
        if op == '>' and node_parts <= base: return False
        if op == '<' and node_parts >= base: return False
        if op in (None, '=') and node_parts != base: return False
    return True

if not any(satisfies_clause(clause) for clause in expression.split('||')):
    raise SystemExit(f'Node.js v{node} 不满足 npm@latest 的 engines.node: {expression}')
PY
}

echo '解析 Node.js 官方 Current 版本。'
curl --connect-timeout 10 --max-time 30 --retry 3 -fsSL \
  https://nodejs.org/dist/index.json -o "$install_tmp/node-index.json"
mapfile -t node_metadata < <(json_value "$install_tmp/node-index.json" node)
[[ ${#node_metadata[@]} == 2 && -n "${node_metadata[0]}" && -n "${node_metadata[1]}" ]] || {
  echo 'Node.js 官方索引缺少 Current 版本或 npm 版本。' >&2
  exit 1
}
node_version="${node_metadata[0]}"
node_bundled_npm="${node_metadata[1]}"
node_archive="node-v${node_version}-linux-${node_arch}.tar.xz"
curl --connect-timeout 10 --max-time 180 --retry 3 -fsSL \
  "https://nodejs.org/dist/v${node_version}/${node_archive}" \
  -o "$install_tmp/$node_archive"
curl --connect-timeout 10 --max-time 30 --retry 3 -fsSL \
  "https://nodejs.org/dist/v${node_version}/SHASUMS256.txt" \
  -o "$install_tmp/node-SHASUMS256.txt"
(cd "$install_tmp"
  awk -v file="$node_archive" '$2 == file { print; found=1 } END { exit(found ? 0 : 1) }' \
    node-SHASUMS256.txt > node-selected.sha256
  sha256sum --strict --check node-selected.sha256
)
node_sha256="$(awk '{print $1}' "$install_tmp/node-selected.sha256")"
node_stage="$install_tmp/node"
mkdir -p "$node_stage"
tar --no-same-owner -xJf "$install_tmp/$node_archive" -C "$node_stage" --strip-components=1
[[ "$("$node_stage/bin/node" --version)" == "v$node_version" ]] || {
  echo 'Node.js 官方归档中的版本与索引不一致。' >&2
  exit 1
}
mv -T "$node_stage" "$PASEO_ROOT/node"
chown -R root:root "$PASEO_ROOT/node"
chmod -R u+rwX,go+rX,go-w "$PASEO_ROOT/node"

echo "解析 npm registry latest（Node.js Current 自带 npm $node_bundled_npm）。"
curl --connect-timeout 10 --max-time 30 --retry 3 -fsSL \
  https://registry.npmjs.org/npm/latest -o "$install_tmp/npm-latest.json"
mapfile -t npm_metadata < <(json_value "$install_tmp/npm-latest.json" npm)
[[ ${#npm_metadata[@]} == 3 ]] || { echo 'npm registry latest 元数据读取失败。' >&2; exit 1; }
npm_version="${npm_metadata[0]}"
npm_engine="${npm_metadata[1]}"
npm_integrity="${npm_metadata[2]}"
check_node_engine "$node_version" "$npm_engine"
# Use Node's own npm to install the current registry latest into the downloaded Node prefix.
env -i HOME=/root PATH="$PASEO_ROOT/node/bin:/usr/local/bin:/usr/bin:/bin" \
  npm_config_cache="$install_tmp/npm-root-cache" npm_config_userconfig=/dev/null \
  npm_config_registry=https://registry.npmjs.org/ \
  "$PASEO_ROOT/node/bin/npm" install --global --prefix "$PASEO_ROOT/node" \
  "npm@$npm_version" --no-audit --no-fund --prefer-online
installed_npm="$(env -i HOME=/root PATH="$PASEO_ROOT/node/bin:/usr/local/bin:/usr/bin:/bin" \
  "$PASEO_ROOT/node/bin/npm" --version)"
[[ "$installed_npm" == "$npm_version" ]] || {
  echo "安装后的 npm $installed_npm 与 registry latest $npm_version 不一致。" >&2
  exit 1
}

install -o root -g root -m 0644 "$PASEO_KIT/apps/package.json" "$PASEO_ROOT/apps/package.json"
chown -R paseo:paseo "$PASEO_ROOT/apps"
echo "从 npm 官方 registry 安装 Paseo CLI 当前 latest 及完整依赖树（npm $installed_npm）。"
npm_install_log="$install_tmp/npm-install.log"
npm_install_command=(
  "$PASEO_ROOT/node/bin/npm" install --prefix "$PASEO_ROOT/apps"
  --omit=dev --no-audit --no-fund --package-lock=true --prefer-online
)
npm_rebuild_command=(
  "$PASEO_ROOT/node/bin/npm" rebuild --prefix "$PASEO_ROOT/apps"
  --omit=dev --no-audit --no-fund
)
run_npm_install() {
  if ! run_as_paseo "${npm_install_command[@]}" >"$npm_install_log" 2>&1; then
    cat "$npm_install_log" >&2
    return 1
  fi
  cat "$npm_install_log"
}
run_npm_rebuild() {
  run_as_paseo "${npm_rebuild_command[@]}"
}
run_npm_install
run_as_paseo "$PASEO_ROOT/node/bin/npm" --prefix "$PASEO_ROOT/apps" install-scripts ls --json \
  >"$install_tmp/npm-scripts.json"
mapfile -t npm_script_packages < <(python3 - "$install_tmp/npm-scripts.json" <<'PY'
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
  printf 'allow-scripts=%s\n' "$allow_scripts" | install -o paseo -g paseo -m 0644 /dev/stdin "$PASEO_ROOT/apps/.npmrc"
  echo "临时允许 npm 当前待构建包：$allow_scripts"
  run_npm_rebuild
  rm -f -- "$PASEO_ROOT/apps/.npmrc"
fi
chown -R root:root "$PASEO_ROOT/apps"
chmod -R u+rwX,go+rX,go-w "$PASEO_ROOT/apps"

[[ -x "$PASEO_ROOT/apps/node_modules/.bin/paseo" ]] || {
  echo 'npm 安装后缺少 Paseo CLI。' >&2
  exit 1
}
[[ ! -e "$PASEO_ROOT/apps/node_modules/@openai/codex" ]] || {
  echo 'Paseo npm 依赖树意外包含 @openai/codex；standalone 安装已停止。' >&2
  exit 1
}
if rg -q '"@openai/codex"' "$PASEO_ROOT/apps/package.json" "$PASEO_ROOT/apps/package-lock.json"; then
  echo 'npm manifest 或 lockfile 意外声明 @openai/codex；standalone 安装已停止。' >&2
  exit 1
fi
paseo_version="$(run_as_paseo "$PASEO_ROOT/apps/node_modules/.bin/paseo" --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
[[ "$paseo_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo '无法从 Paseo CLI 读取正式版本。' >&2
  exit 1
}
paseo_integrity="$(python3 - "$PASEO_ROOT/apps/package-lock.json" <<'PY'
import json
import sys

lock = json.load(open(sys.argv[1], encoding='utf-8'))
entry = lock.get('packages', {}).get('node_modules/@getpaseo/cli', {})
integrity = entry.get('integrity', '')
if not integrity.startswith('sha512-'):
    raise SystemExit('Paseo lockfile 缺少 registry integrity。')
print(integrity)
PY
)"
native_packages="$(python3 - "$PASEO_ROOT/apps/package-lock.json" <<'PY'
import json
import sys

lock = json.load(open(sys.argv[1], encoding='utf-8'))
items = []
for name, entry in lock.get('packages', {}).items():
    if not name.startswith('node_modules/') or not entry.get('hasInstallScript'):
        continue
    package = name.removeprefix('node_modules/')
    items.append(f"{package}@{entry.get('version', '')}")
if not items:
    raise SystemExit('当前 Paseo 依赖树没有可验证的 native/install-script 包。')
print(','.join(sorted(items)))
PY
)"

echo '执行 OpenAI 官方 Codex standalone 安装器。'
curl --connect-timeout 10 --max-time 60 --retry 3 -fsSL \
  https://chatgpt.com/codex/install.sh -o "$install_tmp/codex-install.sh"
grep -Fq 'releases.openai.com/codex' "$install_tmp/codex-install.sh" || {
  echo '下载的 Codex 安装器不是当前 OpenAI 官方安装器。' >&2
  exit 1
}
chmod 0755 "$install_tmp/codex-install.sh"
run_as_paseo /usr/bin/env \
  CODEX_HOME="$PASEO_CODEX_HOME" CODEX_INSTALL_DIR=/srv/paseo/tools/bin \
  CODEX_RELEASE=latest CODEX_NON_INTERACTIVE=1 \
  /bin/sh "$install_tmp/codex-install.sh"
[[ -x "$PASEO_CODEX_BIN" ]] || { echo 'Codex standalone 安装后缺少管理链接。' >&2; exit 1; }
codex_output="$(run_as_paseo "$PASEO_CODEX_BIN" --version)"
codex_version="$(printf '%s\n' "$codex_output" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1)"
[[ "$codex_output" == codex-cli\ * && "$codex_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo '无法从 Codex standalone 读取正式版本。' >&2
  exit 1
}
codex_target="$(readlink -f "$PASEO_CODEX_BIN")"
codex_installer_sha256="$(sha256sum "$install_tmp/codex-install.sh" | awk '{print $1}')"
codex_binary_sha256="$(sha256sum "$codex_target" | awk '{print $1}')"
[[ "$codex_target" == "$PASEO_CODEX_HOME/packages/standalone/"* ]] || {
  echo 'Codex 管理链接未指向官方 standalone 布局。' >&2
  exit 1
}
run_as_paseo "$PASEO_CODEX_BIN" --strict-config --help >/dev/null
run_as_paseo "$PASEO_CODEX_BIN" app-server --help >/dev/null

echo '解析 uv GitHub 正式发行版并校验官方 checksum。'
curl --connect-timeout 10 --max-time 60 --retry 3 -fsSL \
  -H 'Accept: application/vnd.github+json' \
  'https://api.github.com/repos/astral-sh/uv/releases?per_page=100' \
  -o "$install_tmp/uv-releases.json"
mapfile -t uv_metadata < <(json_value "$install_tmp/uv-releases.json" uv)
[[ ${#uv_metadata[@]} == 2 ]] || { echo 'uv GitHub release 元数据读取失败。' >&2; exit 1; }
uv_version="${uv_metadata[0]}"
uv_tag="${uv_metadata[1]}"
uv_archive="uv-${uv_arch}-unknown-linux-gnu.tar.gz"
curl --connect-timeout 10 --max-time 180 --retry 3 -fsSL \
  "https://github.com/astral-sh/uv/releases/download/${uv_tag}/${uv_archive}" \
  -o "$install_tmp/$uv_archive"
curl --connect-timeout 10 --max-time 30 --retry 3 -fsSL \
  "https://github.com/astral-sh/uv/releases/download/${uv_tag}/sha256.sum" \
  -o "$install_tmp/uv-sha256.sum"
python3 - "$install_tmp/uv-sha256.sum" "$uv_archive" "$install_tmp/uv-selected.sha256" <<'PY'
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
(cd "$install_tmp" && sha256sum --strict --check uv-selected.sha256)
uv_sha256="$(awk '{print $1}' "$install_tmp/uv-selected.sha256")"
uv_stage="$install_tmp/uv"
mkdir -p "$uv_stage"
tar --no-same-owner -xzf "$install_tmp/$uv_archive" -C "$uv_stage" --strip-components=1
[[ -x "$uv_stage/uv" && -x "$uv_stage/uvx" ]] || {
  echo 'uv 官方归档缺少 uv 或 uvx 可执行文件。' >&2
  exit 1
}
install -o root -g root -m 0755 "$uv_stage/uv" "$PASEO_ROOT/uv/bin/uv"
install -o root -g root -m 0755 "$uv_stage/uvx" "$PASEO_ROOT/uv/bin/uvx"

install -d -o root -g root -m 0755 "$PASEO_ROOT/lib"
install -o root -g root -m 0644 "$PASEO_KIT/lib/relay-check.mjs" "$PASEO_ROOT/lib/relay-check.mjs"

installed_node="$(run_as_paseo "$PASEO_ROOT/node/bin/node" --version)"
installed_npm="$(run_as_paseo "$PASEO_ROOT/node/bin/npm" --version)"
installed_uv="$(run_as_paseo "$PASEO_ROOT/uv/bin/uv" --version)"
[[ "$installed_node" == "v$node_version" && "$installed_npm" == "$npm_version" ]] || {
  echo '安装后的 Node.js/npm 与官方索引或 registry latest 不一致。' >&2
  exit 1
}
[[ "$installed_uv" == "uv $uv_version "* ]] || {
  echo '安装后的 uv 与 GitHub 正式发行版不一致。' >&2
  exit 1
}

install -o root -g root -m 0644 /dev/stdin "$PASEO_ROOT/.install-complete" <<EOF2
package=$PASEO_RELEASE
node=$node_version
npm=$npm_version
paseo=$paseo_version
codex=$codex_version
uv=$uv_version
node_source=https://nodejs.org/dist/v$node_version/$node_archive
npm_source=https://registry.npmjs.org/npm/-/npm-$npm_version.tgz
paseo_source=https://registry.npmjs.org/@getpaseo/cli
codex_source=https://chatgpt.com/codex/install.sh
codex_home=$PASEO_CODEX_HOME
codex_bin=$PASEO_CODEX_BIN
uv_source=https://github.com/astral-sh/uv/releases/download/$uv_tag/$uv_archive
node_sha256=$node_sha256
npm_integrity=$npm_integrity
paseo_integrity=$paseo_integrity
native_packages=$native_packages
codex_installer_sha256=$codex_installer_sha256
codex_binary_sha256=$codex_binary_sha256
uv_sha256=$uv_sha256
EOF2
chmod 0644 "$PASEO_ROOT/.install-complete"
echo "STEP1_OK：Node.js $node_version、npm $npm_version、Paseo $paseo_version、Codex $codex_version 和 uv $uv_version 已按当前官方版本安装。"
