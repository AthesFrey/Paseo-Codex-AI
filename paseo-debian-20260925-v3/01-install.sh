#!/usr/bin/env bash
# Install the pinned official runtime on a clean Debian host.
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat <<'USAGE'
用法：
  sudo bash 01-install.sh
  sudo bash 01-install.sh --force

--force 停止并重建 Paseo 托管运行时、配置、密钥和应用状态。
它保留 /srv/proj、/srv/paseo/worktrees、/srv/paseo/tools 与 /srv/paseo/cache。
USAGE
}

force=false
if [[ $# == 1 && ( "$1" == '-h' || "$1" == '--help' ) ]]; then
  usage
  exit 0
elif [[ $# == 1 && "$1" == '--force' ]]; then
  force=true
elif [[ $# != 0 ]]; then
  usage >&2
  exit 64
fi

require_root
umask 022

source /etc/os-release
[[ "$ID" == debian && "$VERSION_CODENAME" =~ ^(bookworm|trixie)$ ]] || {
  echo "仅支持 Debian 12 (bookworm) 或 Debian 13 (trixie)。检测到：$PRETTY_NAME" >&2
  exit 1
}
case "$(uname -m)" in
  x86_64) node_arch=x64; uv_arch=x86_64; uv_sha256=23bf5552d220e0842b65c862097b2ebaeba0064b74eda5e565e77fd25969d8c8 ;;
  aarch64) node_arch=arm64; uv_arch=aarch64; uv_sha256=0804e9b164c64b6914182d5920c08551958a095986f10a3731056df701126436 ;;
  *) echo '仅支持 amd64 (x86_64) 或 arm64 (aarch64)。' >&2; exit 1 ;;
esac

if id paseo >/dev/null 2>&1; then
  [[ "$(getent passwd paseo | cut -d: -f6)" == /srv/paseo ]] || {
    echo '已有 paseo 账户但 home 不是 /srv/paseo；已停止，未更改现有部署。' >&2
    exit 1
  }
fi

managed_paths=(
  "$PASEO_ROOT"
  "$PASEO_ETC"
  /etc/systemd/system/paseo.service
  /etc/systemd/system/paseo.service.d
  /srv/paseo/.codex
  /srv/paseo/.paseo
  /srv/paseo/.profile
)
if [[ "$force" != true ]]; then
  for path in "${managed_paths[@]}"; do
    if [[ -e "$path" ]]; then
      echo "检测到已有部署路径：$path；如需清理托管状态并覆盖安装，请使用 --force。" >&2
      exit 1
    fi
  done
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl xz-utils unzip zip bzip2 openssl \
  python3 python3-venv build-essential pkg-config libssl-dev libffi-dev \
  git git-lfs ripgrep jq tmux rsync nftables iproute2 procps util-linux

if [[ "$force" == true ]]; then
  if systemctl is-active --quiet paseo.service; then
    systemctl stop paseo.service
  fi
  if systemctl is-enabled --quiet paseo.service; then
    systemctl disable paseo.service
  fi
  rm -f /etc/systemd/system/paseo.service
  rm -rf /etc/systemd/system/paseo.service.d
  systemctl daemon-reload
  systemctl reset-failed paseo.service >/dev/null 2>&1 || true
  rm -rf "$PASEO_ROOT" "$PASEO_ETC" /srv/paseo/.codex /srv/paseo/.paseo /srv/paseo/.profile
fi

if ! id paseo >/dev/null 2>&1; then
  useradd --create-home --home-dir /srv/paseo --shell /bin/bash --user-group paseo
fi

install -d -o paseo -g paseo -m 0700 /srv/paseo /srv/proj
for directory in .codex .paseo worktrees tools tools/bin; do
  install -d -o paseo -g paseo -m 0700 "/srv/paseo/$directory"
done
ensure_cache_layout
install -d -o root -g root -m 0755 "$PASEO_ROOT" "$PASEO_ROOT/apps" "$PASEO_ROOT/uv/bin"

install_tmp="$(mktemp -d /srv/paseo/cache/paseo-install.XXXXXX)"
cleanup() {
  local status=$?
  rm -rf "$install_tmp"
  return "$status"
}
trap cleanup EXIT

node_version=$PASEO_NODE_VERSION
node_archive="node-v${node_version}-linux-${node_arch}.tar.xz"
curl -fsSL --retry 3 "https://nodejs.org/dist/v${node_version}/${node_archive}" \
  -o "$install_tmp/$node_archive"
curl -fsSL --retry 3 "https://nodejs.org/dist/v${node_version}/SHASUMS256.txt" \
  -o "$install_tmp/SHASUMS256.txt"
(cd "$install_tmp"
  awk -v f="$node_archive" '$2 == f { print; found=1 } END { exit(found ? 0 : 1) }' \
    SHASUMS256.txt > selected-node.sha256
  sha256sum -c selected-node.sha256
)
install -d -o root -g root -m 0755 "$install_tmp/node"
tar --no-same-owner -xJf "$install_tmp/$node_archive" \
  -C "$install_tmp/node" --strip-components=1
"$install_tmp/node/bin/node" --version | grep -Fx "v${node_version}" >/dev/null
mv "$install_tmp/node" "$PASEO_ROOT/node"

install -o root -g root -m 0644 "$PASEO_KIT/apps/package.json" "$PASEO_ROOT/apps/package.json"
install -o root -g root -m 0644 "$PASEO_KIT/apps/package-lock.json" "$PASEO_ROOT/apps/package-lock.json"
export PATH="$PASEO_ROOT/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export npm_config_cache="$install_tmp/npm-cache"
npm ci --prefix "$PASEO_ROOT/apps" --omit=dev --no-audit --no-fund

uv_version=$PASEO_UV_VERSION
uv_archive="uv-${uv_arch}-unknown-linux-gnu.tar.gz"
curl -fsSL --retry 3 \
  "https://github.com/astral-sh/uv/releases/download/${uv_version}/${uv_archive}" \
  -o "$install_tmp/$uv_archive"
printf '%s  %s\n' "$uv_sha256" "$install_tmp/$uv_archive" > "$install_tmp/selected-uv.sha256"
sha256sum -c "$install_tmp/selected-uv.sha256"
install -d -o root -g root -m 0755 "$install_tmp/uv"
tar --no-same-owner -xzf "$install_tmp/$uv_archive" \
  -C "$install_tmp/uv" --strip-components=1
[[ -x "$install_tmp/uv/uv" && -x "$install_tmp/uv/uvx" ]] || {
  echo 'uv 官方归档缺少 uv 或 uvx 可执行文件。' >&2
  exit 1
}
install -o root -g root -m 0755 "$install_tmp/uv/uv" "$PASEO_ROOT/uv/bin/uv"
install -o root -g root -m 0755 "$install_tmp/uv/uvx" "$PASEO_ROOT/uv/bin/uvx"

install -d -o root -g root -m 0755 "$PASEO_ROOT/lib"
install -o root -g root -m 0644 "$PASEO_KIT/lib/relay-check.mjs" "$PASEO_ROOT/lib/relay-check.mjs"

installed_node=$(runuser -u paseo -- env -i HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex PATH="$PASEO_RUNTIME_PATH" "$PASEO_ROOT/node/bin/node" --version)
installed_npm=$(runuser -u paseo -- env -i HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex PATH="$PASEO_RUNTIME_PATH" "$PASEO_ROOT/node/bin/npm" --version)
installed_paseo=$(runuser -u paseo -- env -i HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex PATH="$PASEO_RUNTIME_PATH" "$PASEO_ROOT/apps/node_modules/.bin/paseo" --version)
installed_codex=$(runuser -u paseo -- env -i HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex PATH="$PASEO_RUNTIME_PATH" "$PASEO_ROOT/apps/node_modules/.bin/codex" --version)
installed_uv=$(runuser -u paseo -- env -i HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex PATH="$PASEO_RUNTIME_PATH" "$PASEO_ROOT/uv/bin/uv" --version)
[[ "$installed_node" == "v$PASEO_NODE_VERSION" ]] \
  && [[ "$installed_npm" == "$PASEO_NPM_VERSION" ]] \
  && [[ "$installed_paseo" == *"$PASEO_CLI_VERSION"* ]] \
  && [[ "$installed_codex" == "codex-cli $PASEO_CODEX_VERSION" ]] \
  && [[ "$installed_uv" == "uv $PASEO_UV_VERSION "* ]] || {
    echo '安装后的 Node、npm、Paseo、Codex 或 uv 版本与固定清单不一致。' >&2
    exit 1
  }
printf '%s\n' "$installed_node" "$installed_npm" "$installed_paseo" "$installed_codex" "$installed_uv"

printf 'package=%s\nnode=%s\nnpm=%s\npaseo=%s\ncodex=%s\nuv=%s\n' \
  "$PASEO_RELEASE" \
  "$PASEO_NODE_VERSION" "$PASEO_NPM_VERSION" "$PASEO_CLI_VERSION" \
  "$PASEO_CODEX_VERSION" "$PASEO_UV_VERSION" > "$PASEO_ROOT/.install-complete"
chown root:root "$PASEO_ROOT/.install-complete"
chmod 0644 "$PASEO_ROOT/.install-complete"
echo 'STEP1_OK：Node.js、npm、Paseo、Codex 和 uv 已按当前固定官方版本安装。'
