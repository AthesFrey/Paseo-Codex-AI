#!/usr/bin/env bash
# Verify, pair a client, and verify the daemon.
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_config

run_full_check() {
  python3 "$PASEO_KIT/lib/local-check.py" --wait
  run_as_paseo "$PASEO_ROOT/node/bin/node" "$PASEO_ROOT/lib/relay-check.mjs"
}

run_full_check

echo '下面输出的配对链接相当于访问凭据，仅在自己的 Paseo 客户端使用。'
run_as_paseo /bin/bash --noprofile --norc -c '
  set -Eeuo pipefail
  IFS= read -r -s -p "Paseo 本机管理密码：" PASEO_PASSWORD </dev/tty
  printf "\n"
  export PASEO_PASSWORD
  exec /srv/paseo/runtime/apps/node_modules/.bin/paseo daemon pair --relay --home /srv/paseo/.paseo
'
echo 'PAIRING_READY：二维码/链接已生成。请在手机或 Windows 客户端完成配对。'
if ! IFS= read -r -p '客户端配对完成后按 Enter 继续验收： ' _ </dev/tty; then
  echo '无法从当前终端确认客户端配对状态；未完成最终验收。' >&2
  exit 1
fi

echo '配对后再次验证本机配置、服务、health 和 Relay。'
run_full_check

echo 'CHECK_OK：配对、本机和 Relay 验收通过。'
