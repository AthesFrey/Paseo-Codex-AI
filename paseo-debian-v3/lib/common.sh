# Shared constants for this release.
set -Eeuo pipefail
export SYSTEMD_PAGER=cat SYSTEMD_COLORS=0
PASEO_KIT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PASEO_ROOT=/opt/paseo-v3
PASEO_ETC=/etc/paseo-v3
PASEO_RUNTIME_PATH=/opt/paseo-v3/apps/node_modules/.bin:/opt/paseo-v3/node/bin:/opt/paseo-v3/uv/bin:/srv/paseo/tools/bin:/srv/paseo/tools/cargo/bin:/srv/paseo/tools/go/bin:/usr/local/bin:/usr/bin:/bin
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
run_as_paseo() {
  runuser -u paseo -- env -i \
    HOME=/srv/paseo USER=paseo LOGNAME=paseo \
    CODEX_HOME=/srv/paseo/.codex PASEO_HOME=/srv/paseo/.paseo \
    PATH="$PASEO_RUNTIME_PATH" /bin/bash --noprofile --norc -c \
    'set -Eeuo pipefail; export PATH="$1"; shift; cd /srv/paseo/projects; exec "$@"' \
    bash "$PASEO_RUNTIME_PATH" "$@"
}
