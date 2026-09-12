#!/usr/bin/env bash
# Optional updates for the tools managed by this deployment kit.
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
用法：
  sudo bash 05-update-tools.sh --node-current
  sudo bash 05-update-tools.sh --node-lts
  sudo bash 05-update-tools.sh --paseo
  sudo bash 05-update-tools.sh --codex
  sudo bash 05-update-tools.sh --uv
  sudo bash 05-update-tools.sh --all-current
  sudo bash 05-update-tools.sh --all-lts

说明：
  --node-current  Node.js 官网最新 Current
  --node-lts      Node.js 官网最新 LTS
  --paseo         npm latest 的 @getpaseo/cli
  --codex         npm latest 的 @openai/codex
  --uv            PyPI latest 的 uv
  --all-current   Node Current + Paseo + Codex + uv
  --all-lts       Node LTS + Paseo + Codex + uv
EOF
}
[[ $# == 1 ]] || { usage >&2; exit 64; }
case "$1" in
  --node-current) node_channel=current; update_node=1 ;;
  --node-lts) node_channel=lts; update_node=1 ;;
  --paseo) update_paseo=1 ;;
  --codex) update_codex=1 ;;
  --uv) update_uv=1 ;;
  --all-current) node_channel=current; update_node=1; update_paseo=1; update_codex=1; update_uv=1 ;;
  --all-lts) node_channel=lts; update_node=1; update_paseo=1; update_codex=1; update_uv=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac
require_config
umask 022
# npm uses /usr/bin/env node, including when invoked by its absolute path.
export PATH="$PASEO_ROOT/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

service_was_active=0
if systemctl is-active --quiet paseo.service; then service_was_active=1; fi
node_index=''
node_download=''
node_stage=''
node_backup=''
cleanup_update() {
  local status=$?
  if [[ -n "$node_index" ]]; then rm -f "$node_index"; fi
  if [[ -n "$node_download" && -d "$node_download" ]]; then
    find "$node_download" -mindepth 1 -delete 2>/dev/null || true
    rmdir "$node_download" 2>/dev/null || true
  fi
  if [[ -n "$node_stage" && -d "$node_stage" ]]; then rm -rf "$node_stage"; fi
  if [[ ! -e "$PASEO_ROOT/node" && -n "$node_backup" && -d "$node_backup" ]]; then
    mv "$node_backup" "$PASEO_ROOT/node" || true
  fi
  if (( service_was_active )); then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl start paseo.service >/dev/null 2>&1 || true
  fi
  return "$status"
}
trap cleanup_update EXIT
systemctl stop paseo.service

node_updated=0
if [[ "${update_node:-0}" == 1 ]]; then
  command -v jq >/dev/null || { echo '找不到 jq；无法读取 Node 官网版本索引。' >&2; exit 1; }
  node_arch=''
  case "$(uname -m)" in
    x86_64) node_arch=x64 ;;
    aarch64) node_arch=arm64 ;;
    *) echo '仅支持 amd64/x86_64 或 arm64/aarch64。' >&2; exit 1 ;;
  esac
  node_index="$(mktemp /tmp/paseo-v3.3-node-index.XXXXXX)"
  node_download="$(mktemp -d /tmp/paseo-v3.3-node-download.XXXXXX)"
  curl -fsSL --retry 3 https://nodejs.org/dist/index.json -o "$node_index"
  if [[ "$node_channel" == lts ]]; then
    node_version="$(jq -r 'map(select(.lts != false))[0].version' "$node_index")"
  else
    node_version="$(jq -r '.[0].version' "$node_index")"
  fi
  [[ "$node_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo '无法从 Node 官方索引解析版本。' >&2; exit 1; }
  node_archive="node-${node_version}-linux-${node_arch}.tar.xz"
  curl -fsSL --retry 3 "https://nodejs.org/dist/${node_version}/${node_archive}" -o "$node_download/$node_archive"
  curl -fsSL --retry 3 "https://nodejs.org/dist/${node_version}/SHASUMS256.txt" -o "$node_download/SHASUMS256.txt"
  (cd "$node_download"; awk -v f="$node_archive" '$2 == f { print; found=1 } END { exit(found ? 0 : 1) }' SHASUMS256.txt > selected.sha256; sha256sum -c selected.sha256)
  node_stage="$(mktemp -d "$PASEO_ROOT/node-stage.XXXXXX")"
  tar --no-same-owner -xJf "$node_download/$node_archive" -C "$node_stage" --strip-components=1
  chmod 0755 "$node_stage"
  "$node_stage/bin/node" --version
  node_backup="$PASEO_ROOT/node.previous.$(date +%Y%m%d-%H%M%S)"
  mv "$PASEO_ROOT/node" "$node_backup"
  mv "$node_stage" "$PASEO_ROOT/node"
  node_updated=1
  echo "Node.js 已切换到 $node_version；旧目录保留为 $node_backup。"
  # The trap still cleans downloaded files; node_stage is now the active directory.
  node_stage=''
fi

if (( node_updated == 1 )) || [[ "${update_paseo:-0}" == 1 || "${update_codex:-0}" == 1 ]]; then
  npm_args=(--prefix "$PASEO_ROOT/apps" install --save-exact --omit=dev --no-audit --no-fund)
  [[ "${update_paseo:-0}" == 1 ]] && npm_args+=("@getpaseo/cli@latest")
  [[ "${update_codex:-0}" == 1 ]] && npm_args+=("@openai/codex@latest")
  if [[ "${update_paseo:-0}" == 1 || "${update_codex:-0}" == 1 ]]; then
    "$PASEO_ROOT/node/bin/npm" "${npm_args[@]}"
  else
    # A Node-only update rebuilds native dependencies from the current lockfile.
    "$PASEO_ROOT/node/bin/npm" ci --prefix "$PASEO_ROOT/apps" --omit=dev --no-audit --no-fund
  fi
  sha256sum "$PASEO_ROOT/apps/package-lock.json" | awk '{print $1}' > "$PASEO_ROOT/.apps-lock.sha256"
  chown root:root "$PASEO_ROOT/.apps-lock.sha256"
  chmod 0644 "$PASEO_ROOT/.apps-lock.sha256"
fi

if [[ "${update_uv:-0}" == 1 ]]; then
  "$PASEO_ROOT/uv/bin/python" -m pip install --upgrade --no-cache-dir uv
fi

runuser -u paseo -- env -i HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex PATH="$PASEO_RUNTIME_PATH" \
  "$PASEO_ROOT/apps/node_modules/.bin/paseo" --version
runuser -u paseo -- env -i HOME=/srv/paseo CODEX_HOME=/srv/paseo/.codex PATH="$PASEO_RUNTIME_PATH" \
  "$PASEO_ROOT/apps/node_modules/.bin/codex" --version
"$PASEO_ROOT/uv/bin/uv" --version
"$PASEO_ROOT/node/bin/node" --version

systemctl daemon-reload
if (( service_was_active )); then
  systemctl start paseo.service
else
  echo '升级前 paseo.service 原本未运行，保持 stopped。'
fi

if (( service_was_active )); then
  for ((attempt=1; attempt<=30; attempt++)); do
    if systemctl is-active --quiet paseo.service && \
      curl --noproxy '*' --connect-timeout 1 --max-time 2 -fsS http://127.0.0.1:6767/api/health >/dev/null; then
      echo 'UPDATE_OK：工具升级完成，Paseo 服务已恢复且本机 health 成功。'
      service_was_active=0
      exit 0
    fi
    sleep 1
  done
  echo 'UPDATE_FAILED：工具版本已变更，但 Paseo 未通过启动/health 检查。' >&2
  systemctl --no-pager --full status paseo.service || true
  journalctl -u paseo.service -n 80 --no-pager
  exit 1
fi

echo 'UPDATE_OK：工具升级完成；升级前服务未运行，未自动启动。'
