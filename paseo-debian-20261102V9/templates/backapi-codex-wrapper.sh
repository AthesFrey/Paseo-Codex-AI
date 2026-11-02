#!/usr/bin/env bash
set -Eeuo pipefail
: "${BACKAPI_API_KEY:?BACKAPI_API_KEY is not available to the BackAPI provider}"
export OPENAI_API_KEY="$BACKAPI_API_KEY"
exec /srv/paseo/tools/bin/codex --profile backapi "$@"
