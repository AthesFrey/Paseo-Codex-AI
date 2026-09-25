#!/usr/bin/env bash
# Configure the current Paseo daemon and its primary API provider.
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
        and not any(char in value for char in "\\\"'\\\\")
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

BASE_URL="$base_url" CODEX_CONFIG=/srv/paseo/.codex/config.toml python3 - <<'PY'
import json
import os
import re
import stat
import tempfile
import tomllib
from pathlib import Path

path = Path(os.environ['CODEX_CONFIG'])
base_url = os.environ['BASE_URL']
original = path.stat()
lines = path.read_text().splitlines(keepends=True)
section_name = '[model_providers.hahaapi]'
section_start = next((i for i, line in enumerate(lines) if line.strip() == section_name), None)
if section_start is None:
    raise SystemExit('Codex 配置缺少主 API provider；未启动服务。')
section_end = next((i for i in range(section_start + 1, len(lines)) if lines[i].lstrip().startswith('[')), len(lines))
base_url_line = next((i for i in range(section_start + 1, section_end) if re.match(r'^\s*base_url\s*=', lines[i])), None)
replacement = f'base_url = {json.dumps(base_url)}\n'
if base_url_line is None:
    lines.insert(section_start + 1, replacement)
else:
    newline = '\n' if lines[base_url_line].endswith('\n') else ''
    indent = lines[base_url_line][:len(lines[base_url_line]) - len(lines[base_url_line].lstrip())]
    lines[base_url_line] = indent + replacement.rstrip('\n') + newline
updated = ''.join(lines)
tomllib.loads(updated)
fd, temporary = tempfile.mkstemp(prefix='.config.toml.', dir=str(path.parent), text=True)
with os.fdopen(fd, 'w') as stream:
    stream.write(updated)
os.chown(temporary, original.st_uid, original.st_gid)
os.chmod(temporary, stat.S_IMODE(original.st_mode))
os.replace(temporary, path)
PY
echo '主 API 地址已写入 Codex 配置（已确保使用 /v1）。'

python3 - <<'PY'
import shlex
from pathlib import Path

lines = Path('/etc/paseo/runtime.env').read_text().splitlines()
profile = ['# Paseo service environment; credentials are intentionally absent.']
for line in lines:
    if not line or line.startswith('#'):
        continue
    key, value = line.split('=', 1)
    profile.append(f'export {key}={shlex.quote(value)}')
Path('/srv/paseo/.profile').write_text('\n'.join(profile) + '\n')
PY
chown paseo:paseo /srv/paseo/.profile
chmod 0600 /srv/paseo/.profile

python3 - <<'PY'
import json
from pathlib import Path

config = json.loads(Path('/srv/paseo/.paseo/config.json').read_text())
daemon = config['daemon']
assert daemon['listen'] == '127.0.0.1:6767'
assert daemon['relay']['enabled'] is True
assert daemon['relay']['useTls'] is True
assert daemon['relay']['publicUseTls'] is True
assert config['features']['webUi']['enabled'] is False
print('Paseo 配置检查通过。')
PY

if [[ ! -e "$PASEO_ETC/hahaapi.env" ]]; then
  python3 - <<'PY'
import getpass
import os
import warnings
from pathlib import Path

warnings.simplefilter('error', getpass.GetPassWarning)
key = getpass.getpass('输入 HAHA_API_KEY（不回显）：')
if not key.strip() or any(ch in key for ch in '\r\n') or '\x00' in key:
    raise SystemExit('API key 不能为空且不能包含换行/NUL；未写入。')
value = '"' + key.replace('\\', '\\\\').replace('"', '\\"') + '"'
path = Path('/etc/paseo/hahaapi.env')
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as stream:
    stream.write('HAHA_API_KEY=' + value + '\n')
os.chown(path, 0, 0)
os.chmod(path, 0o600)
print('API key 已保存为 root:root 0600，未显示内容。')
PY
else
  [[ "$(stat -c '%u:%g %a' "$PASEO_ETC/hahaapi.env")" == '0:0 600' ]] || {
    echo 'API key 文件必须是 root:root、0600；已停止。' >&2
    exit 1
  }
  python3 - <<'PY'
from pathlib import Path

text = Path('/etc/paseo/hahaapi.env').read_text()
assert any(line.startswith('HAHA_API_KEY=') and len(line.split('=', 1)[1].strip()) > 2 for line in text.splitlines()), 'API key 文件没有非空 HAHA_API_KEY；未启动服务。'
PY
  echo '保留已有 API key（未显示内容）。'
fi

if ! IFS= read -r -p '是否配置可选 BackAPI？[y/N]： ' configure_backapi </dev/tty; then
  echo '无法从当前终端读取 BackAPI 选择；未启动服务。' >&2
  exit 1
fi
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
    if [[ ! -e "$backapi_env" ]]; then
      BACKAPI_ENV="$backapi_env" python3 - <<'PY'
import getpass
import os
import warnings
from pathlib import Path

warnings.simplefilter('error', getpass.GetPassWarning)
key = getpass.getpass('输入 BACKAPI_API_KEY（不回显）：')
if not key.strip() or any(ch in key for ch in '\r\n') or '\x00' in key:
    raise SystemExit('API key 不能为空且不能包含换行/NUL；未写入。')
value = '"' + key.replace('\\', '\\\\').replace('"', '\\"') + '"'
path = Path(os.environ['BACKAPI_ENV'])
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as stream:
    stream.write('BACKAPI_API_KEY=' + value + '\n')
os.chown(path, 0, 0)
os.chmod(path, 0o600)
print('BackAPI key 已保存为 root:root 0600，未显示内容。')
PY
    else
      [[ "$(stat -c '%u:%g %a' "$backapi_env")" == '0:0 600' ]] || {
        echo 'BackAPI key 文件必须是 root:root、0600；已停止。' >&2
        exit 1
      }
      BACKAPI_ENV="$backapi_env" python3 - <<'PY'
import os
from pathlib import Path

text = Path(os.environ['BACKAPI_ENV']).read_text()
assert any(line.startswith('BACKAPI_API_KEY=') and len(line.split('=', 1)[1].strip()) > 2 for line in text.splitlines()), 'BACKAPI_API_KEY 为空；未启动服务。'
PY
      echo '保留已有 BackAPI key（未显示内容）。'
    fi

    wrapper="$PASEO_ROOT/apps/backapi-codex-wrapper"
    install -o root -g root -m 0755 /dev/stdin "$wrapper" <<'WRAPPER'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${BACKAPI_API_KEY:?BACKAPI_API_KEY is not available to the BackAPI provider}"
export OPENAI_API_KEY="$BACKAPI_API_KEY"
exec /srv/paseo/runtime/apps/node_modules/.bin/codex "$@"
WRAPPER

    dropin=/etc/systemd/system/paseo.service.d/10-backapi.conf
    install -d -o root -g root -m 0755 "${dropin%/*}"
    install -o root -g root -m 0644 /dev/stdin "$dropin" <<DROPIN
[Service]
EnvironmentFile=-$backapi_env
DROPIN

    config=/srv/paseo/.paseo/config.json
    python3 - "$config" "$backapi_base_url" "$wrapper" <<'PY'
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
original = path.stat()
config = json.loads(path.read_text())
providers = config.setdefault('agents', {}).setdefault('providers', {})
providers['codex-bk'] = {
    'extends': 'codex',
    'label': 'Codex_bk',
    'description': 'Codex via BackAPI',
    'enabled': True,
    'order': 20,
    'command': [sys.argv[3]],
    'env': {
        'OPENAI_BASE_URL': sys.argv[2],
        'OPENAI_API_KEY': '__PASEO_BACKAPI_KEY_FROM_SYSTEMD__',
    },
    'models': [{
        'id': 'gpt-6-astra',
        'label': 'gpt-6-astra (BackAPI)',
        'isDefault': True,
        'thinkingOptions': [
            {'id': 'low', 'label': 'Low'},
            {'id': 'medium', 'label': 'Medium'},
            {'id': 'high', 'label': 'High', 'isDefault': True},
            {'id': 'xhigh', 'label': 'Extra High'},
            {'id': 'max', 'label': 'Max'},
        ],
    }],
}
fd, temporary = tempfile.mkstemp(prefix='.config.json.', dir=str(path.parent), text=True)
with os.fdopen(fd, 'w') as stream:
    json.dump(config, stream, ensure_ascii=False, indent=2)
    stream.write('\n')
os.chown(temporary, original.st_uid, original.st_gid)
os.chmod(temporary, stat.S_IMODE(original.st_mode))
os.replace(temporary, path)
PY

    python3 - "$config" "$backapi_base_url" "$wrapper" <<'PY'
import json
import sys
from pathlib import Path

provider = json.loads(Path(sys.argv[1]).read_text())['agents']['providers']['codex-bk']
assert provider['extends'] == 'codex'
assert provider['label'] == 'Codex_bk'
assert provider['command'] == [sys.argv[3]]
assert provider['env']['OPENAI_BASE_URL'] == sys.argv[2]
model = provider['models'][0]
assert model['id'] == 'gpt-6-astra'
assert [item['id'] for item in model['thinkingOptions']] == ['low', 'medium', 'high', 'xhigh', 'max']
print('BACKAPI_CONFIG_OK：Codex_bk、BackAPI 地址和五档思考难度已配置。')
PY
    ;;
  ''|n|no)
    rm -f "$PASEO_ETC/backapi.env" \
      "$PASEO_ROOT/apps/backapi-codex-wrapper" \
      /etc/systemd/system/paseo.service.d/10-backapi.conf
    echo '跳过可选 BackAPI 配置。'
    ;;
  *)
    echo '请输入 y 或 n。' >&2
    exit 64
    ;;
esac

auth_state="$(python3 - <<'PY'
import json
from pathlib import Path

config = json.loads(Path('/srv/paseo/.paseo/config.json').read_text())
print('set' if config.get('daemon', {}).get('auth', {}).get('password') else 'missing')
PY
)"
if [[ "$auth_state" == missing ]]; then
  echo '现在设置 Paseo 本机管理密码（按提示输入两次）。'
  runuser -u paseo -- env -i HOME=/srv/paseo USER=paseo LOGNAME=paseo \
    CODEX_HOME=/srv/paseo/.codex PASEO_HOME=/srv/paseo/.paseo PATH="$PASEO_RUNTIME_PATH" \
    "$PASEO_ROOT/apps/node_modules/.bin/paseo" daemon set-password \
    --home /srv/paseo/.paseo </dev/tty
else
  echo '保留已有 Paseo 本机管理密码哈希。'
fi

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
