#!/usr/bin/env bash
# Display pairing material only to the operator's terminal; no pairing output file.
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_config
python3 "$PASEO_KIT/lib/local-check.py" --wait
run_as_paseo "$PASEO_ROOT/node/bin/node" "$PASEO_ROOT/lib/relay-check.mjs"
echo '下面输出的配对链接相当于访问凭据，仅在自己的 Paseo 客户端使用。'
# Read the password inside the target user's shell; never place its value in argv.
run_as_paseo /bin/bash --noprofile --norc -c '
  set -Eeuo pipefail
  IFS= read -r -s -p "Paseo 本机管理密码：" PASEO_PASSWORD </dev/tty
  printf "\n"
  export PASEO_PASSWORD
  exec /srv/paseo/runtime/apps/node_modules/.bin/paseo daemon pair --relay --home /srv/paseo/.paseo
'
echo 'PAIRING_READY：二维码/链接已生成。手机扫码或 Windows 粘贴配对链接，再验证客户端连接。'
