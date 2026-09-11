#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_config
python3 "$PASEO_KIT/lib/local-check.py" --wait
run_as_paseo "$PASEO_ROOT/node/bin/node" "$PASEO_ROOT/lib/relay-check.mjs"
echo 'CHECK_OK：本机和 Relay 往返检查通过；手机/Windows 和第三方 API 仍要分别验收。'
