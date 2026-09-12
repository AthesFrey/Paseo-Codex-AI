#!/usr/bin/env bash
# Idempotent v3.3 base installation. Re-running preserves newer managed tools.
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
umask 022

source /etc/os-release
[[ "$ID" == debian && "$VERSION_CODENAME" =~ ^(bookworm|trixie)$ ]] || {
  echo "仅支持 Debian 12 (bookworm) 或 Debian 13 (trixie)。检测到：$PRETTY_NAME" >&2
  exit 1
}
case "$(uname -m)" in
  x86_64) node_arch=x64 ;;
  aarch64) node_arch=arm64 ;;
  *) echo '仅支持 amd64 (x86_64) 或 arm64 (aarch64)。' >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive

paseo_service_was_active=0
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet paseo.service 2>/dev/null; then
  paseo_service_was_active=1
  systemctl stop paseo.service
fi
download_dir=''
node_stage=''
restore_paseo_service() {
  local status=$?
  if [[ -n "$download_dir" && -d "$download_dir" ]]; then
    find "$download_dir" -mindepth 1 -delete 2>/dev/null || true
    rmdir "$download_dir" 2>/dev/null || true
  fi
  if [[ -n "$node_stage" && -d "$node_stage" ]]; then
    rm -rf "$node_stage"
  fi
  if (( paseo_service_was_active == 1 )); then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl start paseo.service >/dev/null 2>&1 || true
  fi
  return "$status"
}
trap restore_paseo_service EXIT

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl xz-utils unzip zip bzip2 openssl \
  python3 python3-venv build-essential pkg-config libssl-dev libffi-dev \
  git git-lfs ripgrep jq tmux rsync nftables iproute2

# Create the service account before placing the runtime inside its home.
if id paseo >/dev/null 2>&1; then
  [[ "$(getent passwd paseo | cut -d: -f6)" == /srv/paseo ]] || {
    echo '已有 paseo 用户但 home 不是 /srv/paseo；已停止，避免改动其他账户。' >&2
    exit 1
  }
else
  useradd --create-home --home-dir /srv/paseo --shell /bin/bash --user-group paseo
fi
install -d -o paseo -g paseo -m 0700 /srv/paseo /srv/proj
for directory in .codex .paseo worktrees tools tools/bin cache cache/tmp; do
  install -d -o paseo -g paseo -m 0700 "/srv/paseo/$directory"
done
install -d -o root -g root -m 0755 "$PASEO_ROOT"

# Do not overwrite a Node version that was deliberately upgraded by 05-update-tools.sh.
node_ready=0
if [[ -x "$PASEO_ROOT/node/bin/node" && -x "$PASEO_ROOT/node/bin/npm" ]] && \
  "$PASEO_ROOT/node/bin/node" --version >/dev/null 2>&1; then
  node_ready=1
fi
if (( node_ready == 0 )); then
  download_dir="$(mktemp -d /tmp/paseo-v3.3-download.XXXXXX)"
  node_version=24.21.0
  node_archive="node-v${node_version}-linux-${node_arch}.tar.xz"
  curl -fsSL --retry 3 "https://nodejs.org/dist/v${node_version}/${node_archive}" \
    -o "$download_dir/$node_archive"
  curl -fsSL --retry 3 "https://nodejs.org/dist/v${node_version}/SHASUMS256.txt" \
    -o "$download_dir/SHASUMS256.txt"
  (cd "$download_dir"; awk -v f="$node_archive" '$2 == f { print }' SHASUMS256.txt > selected.sha256; test -s selected.sha256; sha256sum -c selected.sha256)
  node_stage="$(mktemp -d "$PASEO_ROOT/node-stage.XXXXXX")"
  tar --no-same-owner -xJf "$download_dir/$node_archive" -C "$node_stage" --strip-components=1
  # mktemp creates 0700; the service user must be able to traverse the runtime.
  chmod 0755 "$node_stage"
  "$node_stage/bin/node" --version
  rm -rf "$PASEO_ROOT/node"
  mv "$node_stage" "$PASEO_ROOT/node"
  node_stage=''
  find "$download_dir" -mindepth 1 -delete
  rmdir "$download_dir"
  download_dir=''
else
  echo "保留已有 Node.js：$($PASEO_ROOT/node/bin/node --version)"
fi

# Reinstall only when the installed lockfile changed or node_modules is incomplete.
install -d -m 0755 "$PASEO_ROOT/apps"
[[ -e "$PASEO_ROOT/apps/package.json" ]] || \
  install -m 0644 "$PASEO_KIT/apps/package.json" "$PASEO_ROOT/apps/package.json"
[[ -e "$PASEO_ROOT/apps/package-lock.json" ]] || \
  install -m 0644 "$PASEO_KIT/apps/package-lock.json" "$PASEO_ROOT/apps/package-lock.json"
apps_lock_hash="$(sha256sum "$PASEO_ROOT/apps/package-lock.json" | awk '{print $1}')"
apps_stamp="$PASEO_ROOT/.apps-lock.sha256"
if [[ ! -x "$PASEO_ROOT/apps/node_modules/.bin/paseo" || ! -x "$PASEO_ROOT/apps/node_modules/.bin/codex" || ! -f "$apps_stamp" || "$(cat "$apps_stamp" 2>/dev/null || true)" != "$apps_lock_hash" ]]; then
  export PATH="$PASEO_ROOT/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  npm ci --prefix "$PASEO_ROOT/apps" --omit=dev --no-audit --no-fund
  printf '%s\n' "$apps_lock_hash" > "$apps_stamp"
  chown root:root "$apps_stamp"
  chmod 0644 "$apps_stamp"
else
  echo 'Paseo/Codex npm 依赖未变化，保留现有 node_modules。'
fi

if [[ ! -x "$PASEO_ROOT/uv/bin/uv" ]]; then
  python3 -m venv "$PASEO_ROOT/uv"
  "$PASEO_ROOT/uv/bin/pip" install --disable-pip-version-check --no-input 'uv==0.12.13'
else
  echo "保留已有 uv：$($PASEO_ROOT/uv/bin/uv --version)"
fi

install -d -m 0755 "$PASEO_ROOT/lib"
install -m 0644 "$PASEO_KIT/lib/relay-check.mjs" "$PASEO_ROOT/lib/relay-check.mjs"

runuser -u paseo -- env -i HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex PATH="$PASEO_RUNTIME_PATH" \
  "$PASEO_ROOT/apps/node_modules/.bin/paseo" --version
runuser -u paseo -- env -i HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex PATH="$PASEO_RUNTIME_PATH" \
  "$PASEO_ROOT/apps/node_modules/.bin/codex" --version
runuser -u paseo -- env -i HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex PATH="$PASEO_RUNTIME_PATH" \
  "$PASEO_ROOT/uv/bin/uv" --version

printf 'paseo-debian-v3.3 install complete\n' > "$PASEO_ROOT/.install-complete"
chown root:root "$PASEO_ROOT/.install-complete"
chmod 0644 "$PASEO_ROOT/.install-complete"
echo 'STEP1_OK：基础依赖、Node、Paseo、Codex 和 uv 已就绪；可重复执行。'
