#!/usr/bin/env bash
# Add or update the independent Codex-compatible BackAPI provider interactively.
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat <<'USAGE'
用法：
  sudo bash 06-configure-backapi.sh

按提示输入 BackAPI HTTPS 地址和 API key；地址可省略末尾 /v1，脚本会自动补齐。
USAGE
}

if [[ $# != 0 ]]; then
  if [[ $# == 1 && ( "$1" == '-h' || "$1" == '--help' ) ]]; then
    usage
    exit 0
  fi
  usage >&2
  exit 64
fi

require_config

if ! IFS= read -r -p '输入 BackAPI 供应商地址（HTTPS，可省略末尾 /v1）： ' base_url </dev/tty; then
  echo '无法从当前终端读取 BackAPI 供应商地址；未修改配置。' >&2
  exit 1
fi
if ! python3 - "$base_url" <<'PY'
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
        and not any(char in value for char in "\"'\\")
    )
    parsed.port
except ValueError:
    valid = False
if not valid:
    raise SystemExit(1)
PY
then
  echo 'BackAPI 地址必须是 https:// URL。' >&2
  exit 1
fi
while [[ "$base_url" == */ ]]; do base_url="${base_url%/}"; done
[[ "$base_url" == */v1 ]] || base_url="$base_url/v1"

backapi_env="$PASEO_ETC/backapi.env"
install -d -o root -g root -m 0700 "$PASEO_ETC"
if [[ ! -e "$backapi_env" ]]; then
  BACKAPI_ENV="$backapi_env" python3 - <<'PY'
import getpass, os, warnings
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
codex_config=/srv/paseo/.codex/config.toml
python3 - "$config" "$base_url" "$wrapper" <<'PY'
import json, os, stat, sys, tempfile
from pathlib import Path

path = Path(sys.argv[1])
original = path.stat()
config = json.loads(path.read_text())
providers = config.setdefault('agents', {}).setdefault('providers', {})
existing = providers.get('codex-bk')
if existing is not None and existing.get('extends') not in (None, 'codex'):
    raise SystemExit('已有 codex-bk 不是 Codex 派生 provider；为避免覆盖，已停止。')
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

python3 - "$codex_config" <<'PY'
import ast, os, re, stat, sys, tempfile, tomllib
from pathlib import Path

path = Path(sys.argv[1])
original = path.stat()
text = path.read_text()
needed = ['HAHA_API_KEY', 'BACKAPI_API_KEY', 'OPENAI_API_KEY']
section_pattern = re.compile(r'(?ms)^\[shell_environment_policy\][ \t]*$.*?(?=^\[|\Z)')
section_match = section_pattern.search(text)
if section_match:
    section = section_match.group(0)
    exclude_match = re.search(r'(?ms)^(exclude\s*=\s*)\[(.*?)\]', section)
    if exclude_match:
        values = ast.literal_eval('[' + exclude_match.group(2) + ']')
        for item in needed:
            if item not in values:
                values.append(item)
        replacement = exclude_match.group(1) + repr(values)
        section = section[:exclude_match.start()] + replacement + section[exclude_match.end():]
    else:
        section = section.rstrip() + '\nexclude = ' + repr(needed) + '\n'
    text = text[:section_match.start()] + section + text[section_match.end():]
else:
    text += '\n[shell_environment_policy]\nexclude = ' + repr(needed) + '\n'
tomllib.loads(text)
fd, temporary = tempfile.mkstemp(prefix='.config.toml.', dir=str(path.parent), text=True)
with os.fdopen(fd, 'w') as stream:
    stream.write(text)
os.chown(temporary, original.st_uid, original.st_gid)
os.chmod(temporary, stat.S_IMODE(original.st_mode))
os.replace(temporary, path)
PY

systemctl daemon-reload
systemctl restart paseo.service

python3 - "$config" "$base_url" "$wrapper" <<'PY'
import json, sys
from pathlib import Path

provider = json.loads(Path(sys.argv[1]).read_text())['agents']['providers']['codex-bk']
assert provider['extends'] == 'codex' and provider['label'] == 'Codex_bk'
assert provider['command'] == [sys.argv[3]]
assert provider['env']['OPENAI_BASE_URL'] == sys.argv[2]
model = provider['models'][0]
assert model['id'] == 'gpt-6-astra'
assert [item['id'] for item in model['thinkingOptions']] == ['low', 'medium', 'high', 'xhigh', 'max']
print('BACKAPI_CONFIG_OK：Codex_bk、BackAPI 地址和五档思考难度已配置。')
PY

python3 "$PASEO_KIT/lib/local-check.py" --wait
echo 'BACKAPI_READY：请在客户端刷新 provider 列表，选择 Codex_bk → gpt-6-astra (BackAPI)。'
