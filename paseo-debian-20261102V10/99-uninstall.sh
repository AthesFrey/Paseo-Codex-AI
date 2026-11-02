#!/usr/bin/env bash
# Remove only tool-managed Paseo resources; preserve user data and tools.
set -Eeuo pipefail

export SYSTEMD_PAGER=cat SYSTEMD_COLORS=0

readonly PACKAGE_DIR_NAME='paseo-debian-20261102V10'
readonly CODEX_HOME='/srv/paseo/.codex'
readonly CODEX_BIN='/srv/paseo/tools/bin/codex'
readonly CODEX_STANDALONE="$CODEX_HOME/packages/standalone"
readonly CLAUDE_HOME='/srv/paseo/.local/share/claude'
readonly CLAUDE_LOCAL_BIN='/srv/paseo/.local/bin/claude'
readonly CLAUDE_BIN='/srv/paseo/tools/bin/claude'
script_source="${BASH_SOURCE[0]-}"
if [[ -n "$script_source" && -f "$script_source" ]]; then
  PASEO_KIT="$(cd -- "$(dirname -- "$script_source")" && pwd)"
else
  PASEO_KIT="/srv/paseo/deploy-kit/$PACKAGE_DIR_NAME"
fi

usage() {
  cat <<'USAGE'
用法：
  sudo bash 99-uninstall.sh --dry-run
  sudo bash 99-uninstall.sh --yes
  curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261102V10/99-uninstall.sh | sudo bash -s -- --dry-run
  curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261102V10/99-uninstall.sh | sudo bash -s -- --yes

--dry-run 仅列出将删除的 Paseo 托管资源。
--yes 执行卸载。即使安装中断且部署包尚未保存，也可直接从本脚本卸载。
USAGE
}

[[ $# == 1 ]] || { usage >&2; exit 64; }
case "$1" in
  --dry-run) mode=dry-run ;;
  --yes) mode=execute ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac

[[ $EUID == 0 ]] || { echo '请以 root 或 sudo bash 执行。' >&2; exit 1; }
for command in readlink systemctl; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "找不到 $command；为避免删除仍在运行的服务文件，停止卸载。" >&2
    exit 1
  }
done

codex_link_managed=false
if [[ -L "$CODEX_BIN" ]]; then
  if codex_target="$(readlink -m -- "$CODEX_BIN")" \
    && [[ "$codex_target" == "$CODEX_STANDALONE/"* ]]; then
    codex_link_managed=true
  else
    echo "保留非本工具管理的 Codex 路径：$CODEX_BIN"
  fi
elif [[ -e "$CODEX_BIN" ]]; then
  echo "保留非本工具管理的 Codex 路径：$CODEX_BIN"
fi

claude_install_managed=false
if [[ -L "$CLAUDE_LOCAL_BIN" ]]; then
  if claude_local_target="$(readlink -m -- "$CLAUDE_LOCAL_BIN")" \
    && [[ "$claude_local_target" == "$CLAUDE_HOME/"* ]]; then
    claude_install_managed=true
  else
    echo "保留非 Anthropic 管理的 Claude 命令：$CLAUDE_LOCAL_BIN"
  fi
elif [[ -e "$CLAUDE_LOCAL_BIN" ]]; then
  echo "保留非 Anthropic 管理的 Claude 命令：$CLAUDE_LOCAL_BIN"
fi

claude_path_link_managed=false
if [[ -L "$CLAUDE_BIN" ]]; then
  if [[ "$(readlink -m -- "$CLAUDE_BIN")" == "$CLAUDE_LOCAL_BIN" ]]; then
    claude_path_link_managed=true
  else
    echo "保留非本工具管理的 Claude Code 路径：$CLAUDE_BIN"
  fi
elif [[ -e "$CLAUDE_BIN" ]]; then
  echo "保留非本工具管理的 Claude Code 路径：$CLAUDE_BIN"
fi

managed_paths=(
  /etc/systemd/system/paseo.service
  /etc/paseo
  /srv/paseo/runtime
  "$CODEX_HOME"
  /srv/paseo/.paseo
  /srv/paseo/.profile
)
if [[ "$codex_link_managed" == true ]]; then
  managed_paths+=("$CODEX_BIN")
fi
if [[ "$claude_install_managed" == true ]]; then
  managed_paths+=("$CLAUDE_HOME" "$CLAUDE_LOCAL_BIN")
fi
if [[ "$claude_path_link_managed" == true ]]; then
  managed_paths+=("$CLAUDE_BIN")
fi
for path in "${managed_paths[@]}"; do
  printf '%s\n' "$path"
done
printf '%s\n' \
  '保留：/srv/proj' \
  '保留：/srv/paseo/worktrees' \
  '保留：/srv/paseo/tools（除本工具管理的命令链接外）' \
  '保留：其他 /etc/systemd/system/paseo.service.d drop-in' \
  '保留：/srv/paseo/cache' \
  '保留：paseo 用户和组' \
  "保留：$PASEO_KIT（如存在）"

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
systemctl daemon-reload >/dev/null
systemctl reset-failed paseo.service >/dev/null 2>&1 || true

rm -rf -- /etc/paseo /srv/paseo/runtime "$CODEX_HOME" /srv/paseo/.paseo /srv/paseo/.profile
if [[ "$codex_link_managed" == true ]]; then
  rm -f -- "$CODEX_BIN"
fi
if [[ "$claude_path_link_managed" == true ]]; then
  rm -f -- "$CLAUDE_BIN"
fi
if [[ "$claude_install_managed" == true ]]; then
  rm -f -- "$CLAUDE_LOCAL_BIN"
  rm -rf -- "$CLAUDE_HOME"
fi

echo 'UNINSTALL_OK：Paseo 服务、运行时、配置和本工具管理的 Codex/Claude Code 状态已删除。'
echo '保留了 /srv/proj、/srv/paseo/worktrees、非托管工具、/srv/paseo/cache、paseo 用户和部署包源目录。'
echo '保留了其他 paseo.service.d drop-in。'
