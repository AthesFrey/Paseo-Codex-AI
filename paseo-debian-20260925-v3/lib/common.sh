#!/usr/bin/env bash
# Shared constants for this deployment package.
set -Eeuo pipefail
export SYSTEMD_PAGER=cat SYSTEMD_COLORS=0
# Used by the scripts sourcing this file.
# shellcheck disable=SC2034
PASEO_KIT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PASEO_RELEASE=paseo-debian-20260925-v3
PASEO_ROOT=/srv/paseo/runtime
PASEO_ETC=/etc/paseo
PASEO_CACHE_ROOT=/srv/paseo/cache
PASEO_CACHE_DIRS=(tmp npm-paseo pip uv gomod go-build ms-playwright)
PASEO_NODE_VERSION=26.10.0
PASEO_NPM_VERSION=11.19.1
PASEO_CLI_VERSION=0.9.2
PASEO_CODEX_VERSION=0.157.0
PASEO_UV_VERSION=0.12.19
PASEO_RUNTIME_PATH=/srv/paseo/runtime/apps/node_modules/.bin:/srv/paseo/runtime/node/bin:/srv/paseo/runtime/uv/bin:/srv/paseo/tools/bin:/srv/paseo/tools/cargo/bin:/srv/paseo/tools/go/bin:/usr/local/bin:/usr/bin:/bin
require_root() {
  [[ $EUID == 0 ]] || { echo '请以 root 或 sudo bash 执行。' >&2; exit 1; }
}
require_install() {
  require_root
  [[ -f "$PASEO_ROOT/.install-complete" ]] || { echo '请先完成 01-install.sh。' >&2; exit 1; }
}
require_config() {
  require_install
  [[ -f "$PASEO_ETC/.configured" ]] || { echo '请先完成 02-configure.sh。' >&2; exit 1; }
}
ensure_cache_layout() {
  local directory cache_root="${1:-$PASEO_CACHE_ROOT}"
  install -d -o paseo -g paseo -m 0700 "$cache_root"
  for directory in "${PASEO_CACHE_DIRS[@]}"; do
    install -d -o paseo -g paseo -m 0700 "$cache_root/$directory"
  done
}
run_as_paseo() {
  # The quoted command is expanded by the target shell.
  # shellcheck disable=SC2016
  runuser -u paseo -- env -i \
    HOME=/srv/paseo USER=paseo LOGNAME=paseo \
    CODEX_HOME=/srv/paseo/.codex PASEO_HOME=/srv/paseo/.paseo \
    PATH="$PASEO_RUNTIME_PATH" /bin/bash --noprofile --norc -c \
    'set -Eeuo pipefail; export PATH="$1"; shift; cd /srv/proj; exec "$@"' \
    bash "$PASEO_RUNTIME_PATH" "$@"
}
