#!/usr/bin/env bash
# Shared paths and privilege boundary for the v6.1fix2 deployment.
set -Eeuo pipefail

export SYSTEMD_PAGER=cat SYSTEMD_COLORS=0

PASEO_KIT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PASEO_RELEASE=paseo-debian-20261002-v6.1fix2
PASEO_ROOT=/srv/paseo/runtime
PASEO_ETC=/etc/paseo
PASEO_CACHE_ROOT=/srv/paseo/cache
PASEO_CODEX_HOME=/srv/paseo/.codex
PASEO_CODEX_BIN=/srv/paseo/tools/bin/codex
PASEO_CACHE_DIRS=(tmp npm-paseo pip uv gomod go-build ms-playwright)
PASEO_RUNTIME_PATH=/srv/paseo/runtime/apps/node_modules/.bin:/srv/paseo/runtime/node/bin:/srv/paseo/runtime/uv/bin:/srv/paseo/tools/bin:/srv/paseo/tools/cargo/bin:/srv/paseo/tools/go/bin:/usr/local/bin:/usr/bin:/bin

require_root() {
  [[ $EUID == 0 ]] || { echo '请以 root 或 sudo bash 执行。' >&2; exit 1; }
}

require_install() {
  require_root
  [[ -f "$PASEO_ROOT/.install-complete" ]] || {
    echo '请先完成 01-install.sh。' >&2
    exit 1
  }
}

require_config() {
  require_install
  [[ -f "$PASEO_ETC/.configured" ]] || {
    echo '请先完成 02-configure.sh。' >&2
    exit 1
  }
}

ensure_cache_layout() {
  local directory cache_root="${1:-$PASEO_CACHE_ROOT}"
  install -d -o paseo -g paseo -m 0700 "$cache_root"
  for directory in "${PASEO_CACHE_DIRS[@]}"; do
    install -d -o paseo -g paseo -m 0700 "$cache_root/$directory"
  done
}

run_as_paseo() {
  # The official Codex installer restores its initial cwd in a cleanup path.
  # Entering /root as the unprivileged account produces its misleading
  # "Failed to restore initial working directory" error, so every child gets
  # a known readable cwd before it starts.
  runuser -u paseo -- env -i \
    HOME=/srv/paseo USER=paseo LOGNAME=paseo SHELL=/bin/bash \
    CODEX_HOME="$PASEO_CODEX_HOME" PASEO_HOME=/srv/paseo/.paseo \
    TMPDIR="$PASEO_CACHE_ROOT/tmp" XDG_CACHE_HOME="$PASEO_CACHE_ROOT" \
    npm_config_cache="$PASEO_CACHE_ROOT/npm-paseo" \
    npm_config_prefix=/srv/paseo/tools \
    npm_config_userconfig=/dev/null npm_config_registry=https://registry.npmjs.org/ \
    UV_CACHE_DIR="$PASEO_CACHE_ROOT/uv" \
    UV_PYTHON_INSTALL_DIR=/srv/paseo/tools/python \
    UV_TOOL_DIR=/srv/paseo/tools/uv \
    UV_TOOL_BIN_DIR=/srv/paseo/tools/bin \
    PIP_CACHE_DIR="$PASEO_CACHE_ROOT/pip" \
    CARGO_HOME=/srv/paseo/tools/cargo RUSTUP_HOME=/srv/paseo/tools/rustup \
    GOPATH=/srv/paseo/tools/go GOMODCACHE="$PASEO_CACHE_ROOT/gomod" \
    GOCACHE="$PASEO_CACHE_ROOT/go-build" \
    PLAYWRIGHT_BROWSERS_PATH="$PASEO_CACHE_ROOT/ms-playwright" \
    PATH="$PASEO_RUNTIME_PATH" \
    /bin/bash --noprofile --norc -c \
    'set -Eeuo pipefail; cd -- /srv/proj; exec "$@"' \
    paseo-runner "$@"
}
