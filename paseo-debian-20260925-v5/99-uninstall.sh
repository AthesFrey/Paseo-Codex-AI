#!/usr/bin/env bash
# Remove the paseo-debian-20260925-v5 deployment from the current host.
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root

usage() {
  cat <<'USAGE'
用法：
  sudo bash 99-uninstall.sh --dry-run
  sudo bash 99-uninstall.sh --yes

--dry-run 仅列出将删除的服务、配置、运行时和用户数据。
--yes 执行卸载。/srv/proj、/srv/paseo/worktrees 及项目文件会保留。
USAGE
}

[[ $# == 1 ]] || { usage >&2; exit 64; }
case "$1" in
  --dry-run) mode=dry-run ;;
  --yes) mode=execute ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac

paths=(
  /etc/systemd/system/paseo.service
  /etc/systemd/system/paseo.service.d
  /etc/paseo
  /srv/paseo/runtime
  /srv/paseo/tools
  /srv/paseo/cache
  /srv/paseo/.codex
  /srv/paseo/.paseo
  /srv/paseo/.profile
)
for path in "${paths[@]}"; do
  printf '%s\n' "$path"
done

if id paseo >/dev/null 2>&1; then
  printf '%s\n' 'user:paseo' 'group:paseo'
fi
printf '%s\n' '保留：/srv/proj' '保留：/srv/paseo/worktrees'
printf '保留：%s（部署包源目录）\n' "$PASEO_KIT"

if [[ "$mode" == dry-run ]]; then
  echo 'DRY_RUN：未执行删除。'
  exit 0
fi

systemctl disable --now paseo.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/paseo.service
rm -rf /etc/systemd/system/paseo.service.d
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed paseo.service >/dev/null 2>&1 || true

rm -rf /etc/paseo /srv/paseo/runtime /srv/paseo/tools /srv/paseo/cache \
  /srv/paseo/.codex /srv/paseo/.paseo /srv/paseo/.profile

if id paseo >/dev/null 2>&1; then
  pkill -TERM -u paseo >/dev/null 2>&1 || true
  sleep 1
  pkill -KILL -u paseo >/dev/null 2>&1 || true
  userdel paseo
fi
if getent group paseo >/dev/null 2>&1; then
  groupdel paseo
fi
rmdir /srv/paseo 2>/dev/null || true

echo 'UNINSTALL_OK：当前 Paseo 服务、运行时、配置、工具缓存和 paseo 账户已删除。'
echo '保留了 /srv/proj、/srv/paseo/worktrees 以及部署包源目录。'
