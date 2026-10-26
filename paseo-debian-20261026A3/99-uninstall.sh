#!/usr/bin/env bash
# Remove only tool-managed Paseo resources; preserve user data and tools.
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat <<'USAGE'
用法：
  sudo bash 99-uninstall.sh --dry-run
  sudo bash 99-uninstall.sh --yes

--dry-run 仅列出将删除的 Paseo 托管资源。
--yes 执行卸载。/srv/proj、worktrees、tools、cache、paseo 用户和部署包源目录会保留。
USAGE
}

[[ $# == 1 ]] || { usage >&2; exit 64; }
case "$1" in
  --dry-run) mode=dry-run ;;
  --yes) mode=execute ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac

require_root
command -v systemctl >/dev/null 2>&1 || {
  echo '找不到 systemctl；为避免删除仍在运行的服务文件，停止卸载。' >&2
  exit 1
}

managed_paths=(
  /etc/systemd/system/paseo.service
  /etc/systemd/system/paseo.service.d/10-backapi.conf
  /etc/paseo
  /srv/paseo/runtime
  /srv/paseo/.codex
  /srv/paseo/.paseo
  /srv/paseo/.profile
  /srv/paseo/tools/bin/codex
)
for path in "${managed_paths[@]}"; do
  printf '%s\n' "$path"
done
printf '%s\n' \
  '保留：/srv/proj' \
  '保留：/srv/paseo/worktrees' \
  '保留：/srv/paseo/tools（包括其他用户工具）' \
  '保留：其他 /etc/systemd/system/paseo.service.d drop-in' \
  '保留：/srv/paseo/cache' \
  '保留：paseo 用户和组（仍用于保留的数据目录）' \
  "保留：$PASEO_KIT（部署包源目录）"

if [[ "$mode" == dry-run ]]; then
  echo 'DRY_RUN：未执行删除。'
  exit 0
fi

if systemctl is-active --quiet paseo.service; then
  systemctl stop paseo.service >/dev/null || {
    echo '无法停止 Paseo 服务；保留所有托管文件。' >&2
    exit 1
  }
  if systemctl is-active --quiet paseo.service; then
    echo 'Paseo 服务仍处于活动状态；保留所有托管文件。' >&2
    exit 1
  fi
fi
systemctl disable paseo.service >/dev/null 2>&1 || true
rm -f -- /etc/systemd/system/paseo.service
rm -f -- /etc/systemd/system/paseo.service.d/10-backapi.conf
rmdir /etc/systemd/system/paseo.service.d 2>/dev/null || true
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed paseo.service >/dev/null 2>&1 || true

rm -rf -- /etc/paseo /srv/paseo/runtime /srv/paseo/.codex /srv/paseo/.paseo /srv/paseo/.profile
rm -f -- /srv/paseo/tools/bin/codex

# Do not remove the paseo account: preserved worktrees, tools and caches use it.
echo 'UNINSTALL_OK：Paseo 服务、运行时、配置、Codex standalone 状态和管理链接已删除。'
echo '保留了 /srv/proj、/srv/paseo/worktrees、/srv/paseo/tools、/srv/paseo/cache、paseo 用户和部署包源目录。'
echo '保留了其他 paseo.service.d drop-in。'
