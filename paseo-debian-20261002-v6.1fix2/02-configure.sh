#!/usr/bin/env bash
# Configure the current Paseo daemon, API providers, and manually entered models.
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_install
umask 022

normalize_https_url() {
  local value="$1"
  if ! python3 - "$value" <<'PY'
import sys
from urllib.parse import urlsplit

value = sys.argv[1]
try:
    parsed = urlsplit(value)
    valid = (
        parsed.scheme == 'https'
        and bool(parsed.netloc)
        and bool(parsed.hostname)
        and not parsed.username
        and not parsed.password
        and not parsed.query
        and not parsed.fragment
        and not any(char.isspace() for char in value)
        and not any(char in value for char in "\\\"'\\")
    )
    parsed.port
except ValueError:
    valid = False
if not valid:
    raise SystemExit(1)
PY
  then
    return 1
  fi
  while [[ "$value" == */ ]]; do value="${value%/}"; done
  [[ "$value" == */v1 ]] || value="$value/v1"
  printf '%s\n' "$value"
}

ensure_secret_file() {
  local path="$1" name="$2" prompt="$3"
  local replace_key=false
  if [[ -e "$path" ]]; then
    [[ "$(stat -c '%u:%g %a' "$path")" == '0:0 600' ]] || {
      echo "API key 文件必须是 root:root、0600：$path" >&2
      exit 1
    }
    if ! IFS= read -r -p "是否重新输入 $name？[y/N]： " replace_answer </dev/tty; then
      echo '无法从当前终端读取 API key 选择；未启动服务。' >&2
      exit 1
    fi
    case "${replace_answer,,}" in
      y|yes) replace_key=true ;;
      ''|n|no)
        SECRET_PATH="$path" SECRET_NAME="$name" python3 - <<'PY'
import os
from pathlib import Path

text = Path(os.environ['SECRET_PATH']).read_text(encoding='utf-8')
assert any(
    line.startswith(os.environ['SECRET_NAME'] + '=')
    and len(line.split('=', 1)[1].strip()) > 2
    for line in text.splitlines()
), f"{os.environ['SECRET_NAME']} 为空；未启动服务。"
PY
        echo '保留已有 API key（未显示内容）。'
        return
        ;;
      *)
        echo '请输入 y 或 n。' >&2
        exit 64
        ;;
    esac
  else
    replace_key=true
  fi

  if [[ "$replace_key" == true ]]; then
    SECRET_PATH="$path" SECRET_NAME="$name" SECRET_PROMPT="$prompt" python3 - <<'PY'
import getpass
import os
import tempfile
import warnings
from pathlib import Path

warnings.simplefilter('error', getpass.GetPassWarning)
key = getpass.getpass(os.environ['SECRET_PROMPT'])
if not key.strip() or any(ch in key for ch in '\r\n') or '\x00' in key:
    raise SystemExit('API key 不能为空且不能包含换行/NUL；未写入。')
value = '"' + key.replace('\\', '\\\\').replace('"', '\\"') + '"'
path = Path(os.environ['SECRET_PATH'])
fd, temporary = tempfile.mkstemp(prefix=f'.{path.name}.', dir=str(path.parent), text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        stream.write(os.environ['SECRET_NAME'] + '=' + value + '\n')
    os.chown(temporary, 0, 0)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
print('API key 已保存为 root:root 0600，未显示内容。')
PY
  fi
}

[[ ! -e "$PASEO_ETC/.configured" ]] || {
  echo '此安装已完成；如需全新覆盖，请重新执行 01-install.sh --force。' >&2
  exit 1
}

install -d -o root -g root -m 0700 "$PASEO_ETC"
install -o root -g root -m 0644 "$PASEO_KIT/templates/runtime.env" "$PASEO_ETC/runtime.env"
install -o paseo -g paseo -m 0600 "$PASEO_KIT/templates/codex-config.toml" /srv/paseo/.codex/config.toml
install -o paseo -g paseo -m 0644 "$PASEO_KIT/templates/AGENTS.md" /srv/paseo/.codex/AGENTS.md
install -o paseo -g paseo -m 0600 "$PASEO_KIT/templates/paseo-config.json" /srv/paseo/.paseo/config.json

if ! IFS= read -r -p '输入主 API 供应商地址（HTTPS，可省略末尾 /v1）： ' base_url </dev/tty; then
  echo '无法从当前终端读取主 API 供应商地址；未启动服务。' >&2
  exit 1
fi
if ! base_url="$(normalize_https_url "$base_url")"; then
  echo '主 API 供应商地址必须是 https:// URL。' >&2
  exit 1
fi

main_env="$PASEO_ETC/hahaapi.env"
ensure_secret_file "$main_env" HAHA_API_KEY '输入 HAHA_API_KEY（不回显）：'
echo '不会自动查询主 API 模型列表；请手动输入要导入的模型名称。'
main_selection="$(python3 "$PASEO_KIT/lib/model-selector.py" \
  --label '主 API')"

if ! IFS= read -r -p '是否配置可选 BackAPI？[y/N]： ' configure_backapi </dev/tty; then
  echo '无法从当前终端读取 BackAPI 选择；未启动服务。' >&2
  exit 1
fi

backapi_base_url=''
backapi_env=''
back_selection=''
case "${configure_backapi,,}" in
  y|yes)
    if ! IFS= read -r -p '输入 BackAPI 供应商地址（HTTPS，可省略末尾 /v1）： ' backapi_base_url </dev/tty; then
      echo '无法从当前终端读取 BackAPI 供应商地址；未启动服务。' >&2
      exit 1
    fi
    if ! backapi_base_url="$(normalize_https_url "$backapi_base_url")"; then
      echo 'BackAPI 地址必须是 https:// URL。' >&2
      exit 1
    fi
    backapi_env="$PASEO_ETC/backapi.env"
    ensure_secret_file "$backapi_env" BACKAPI_API_KEY '输入 BACKAPI_API_KEY（不回显）：'
    echo '不会自动查询 BackAPI 模型列表；请手动输入要导入的模型名称。'
    back_selection="$(python3 "$PASEO_KIT/lib/model-selector.py" \
      --label 'BackAPI')"
    ;;
  ''|n|no)
    rm -f "$PASEO_ETC/backapi.env" "$PASEO_ROOT/apps/backapi-codex-wrapper" \
      /etc/systemd/system/paseo.service.d/10-backapi.conf
    echo '跳过可选 BackAPI 配置。'
    ;;
  *)
    echo '请输入 y 或 n。' >&2
    exit 64
    ;;
esac

selection_dir="$PASEO_CACHE_ROOT/tmp"
install -d -m 0700 "$selection_dir"
main_selection_file="$(mktemp "$selection_dir/paseo-main-models.XXXXXX")"
back_selection_file=''
selection_files=("$main_selection_file")
printf '%s\n' "$main_selection" >"$main_selection_file"
chmod 0600 "$main_selection_file"
if [[ -n "$back_selection" ]]; then
  back_selection_file="$(mktemp "$selection_dir/paseo-back-models.XXXXXX")"
  selection_files+=("$back_selection_file")
  printf '%s\n' "$back_selection" >"$back_selection_file"
  chmod 0600 "$back_selection_file"
fi
cleanup_selection_files() {
  rm -f -- "${selection_files[@]}"
}
trap cleanup_selection_files EXIT

wrapper="$PASEO_ROOT/apps/backapi-codex-wrapper"
dropin=/etc/systemd/system/paseo.service.d/10-backapi.conf
if [[ -n "$back_selection_file" ]]; then
  install -o root -g root -m 0755 /dev/stdin "$wrapper" <<'WRAPPER'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${BACKAPI_API_KEY:?BACKAPI_API_KEY is not available to the BackAPI provider}"
export OPENAI_API_KEY="$BACKAPI_API_KEY"
exec /srv/paseo/tools/bin/codex "$@"
WRAPPER
  install -d -o root -g root -m 0755 "${dropin%/*}"
  install -o root -g root -m 0644 /dev/stdin "$dropin" <<DROPIN
[Service]
EnvironmentFile=-$backapi_env
DROPIN
fi

config=/srv/paseo/.paseo/config.json
apply_args=(
  --paseo-config "$config"
  --codex-config /srv/paseo/.codex/config.toml
  --main-selection "$main_selection_file"
  --base-url "$base_url"
  --wrapper "$wrapper"
)
if [[ -n "$back_selection_file" ]]; then
  apply_args+=(--back-selection "$back_selection_file" --backapi-base-url "$backapi_base_url")
fi
python3 "$PASEO_KIT/lib/apply-model-config.py" "${apply_args[@]}"

python3 - <<'PY'
import shlex
from pathlib import Path

lines = Path('/etc/paseo/runtime.env').read_text(encoding='utf-8').splitlines()
profile = ['# Paseo service environment; credentials are intentionally absent.']
for line in lines:
    if not line or line.startswith('#'):
        continue
    key, value = line.split('=', 1)
    profile.append(f'export {key}={shlex.quote(value)}')
Path('/srv/paseo/.profile').write_text('\n'.join(profile) + '\n', encoding='utf-8')
PY
chown paseo:paseo /srv/paseo/.profile
chmod 0600 /srv/paseo/.profile

python3 - <<'PY'
import json
from pathlib import Path

config = json.loads(Path('/srv/paseo/.paseo/config.json').read_text(encoding='utf-8'))
daemon = config['daemon']
assert daemon['listen'] == '127.0.0.1:6767'
assert daemon['relay']['enabled'] is True
assert daemon['relay']['useTls'] is True
assert daemon['relay']['publicUseTls'] is True
assert config['features']['webUi']['enabled'] is False
models = config['agents']['providers']['codex']['models']
assert models and sum(item.get('isDefault', False) for item in models) == 1
assert config['agents']['metadataGeneration']['providers'][0]['model'] == next(
    item['id'] for item in models if item.get('isDefault')
)
print('Paseo 配置检查通过。')
PY

auth_state="$(python3 - <<'PY'
import json
from pathlib import Path

config = json.loads(Path('/srv/paseo/.paseo/config.json').read_text(encoding='utf-8'))
print('set' if config.get('daemon', {}).get('auth', {}).get('password') else 'missing')
PY
)"
if [[ "$auth_state" == missing ]]; then
  echo '现在设置 Paseo 本机管理密码（按提示输入两次）。'
  run_as_paseo "$PASEO_ROOT/apps/node_modules/.bin/paseo" daemon set-password \
    --home /srv/paseo/.paseo </dev/tty
else
  echo '保留已有 Paseo 本机管理密码哈希。'
fi

echo '使用当前 Paseo CLI 重新解析 v1 配置。'
run_as_paseo "$PASEO_ROOT/apps/node_modules/.bin/paseo" daemon config get \
  --home /srv/paseo/.paseo >/dev/null

install -o root -g root -m 0644 "$PASEO_KIT/templates/paseo.service" /etc/systemd/system/paseo.service
systemd-analyze verify /etc/systemd/system/paseo.service
systemctl daemon-reload
systemctl enable paseo.service
systemctl restart paseo.service

if python3 "$PASEO_KIT/lib/local-check.py" --wait; then
  install -o root -g root -m 0644 /dev/null "$PASEO_ETC/.configured"
  echo 'STEP2_OK：Paseo daemon、Relay 和本地 health 检查通过。'
else
  systemctl --no-pager --full status paseo.service || true
  journalctl -u paseo.service -n 40 --no-pager
  exit 1
fi
