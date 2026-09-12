#!/usr/bin/env bash
# Interactive v3.3 configuration. Re-running updates the selected API address.
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_install

for path in /srv/paseo/.codex/config.toml /srv/paseo/.paseo/config.json \
  /srv/paseo/.codex/AGENTS.md /srv/paseo/.profile \
  "$PASEO_ETC" "$PASEO_ETC/runtime.env"; do
  if [[ -e "$path" ]]; then
    echo "保留已有 $path"
  fi
done

install -d -o root -g root -m 0700 "$PASEO_ETC"
[[ -e "$PASEO_ETC/runtime.env" ]] || install -o root -g root -m 0644 "$PASEO_KIT/templates/runtime.env" "$PASEO_ETC/runtime.env"
[[ -e /srv/paseo/.codex/config.toml ]] || install -o paseo -g paseo -m 0600 "$PASEO_KIT/templates/codex-config.toml" /srv/paseo/.codex/config.toml
[[ -e /srv/paseo/.codex/AGENTS.md ]] || install -o paseo -g paseo -m 0644 "$PASEO_KIT/templates/AGENTS.md" /srv/paseo/.codex/AGENTS.md
[[ -e /srv/paseo/.paseo/config.json ]] || install -o paseo -g paseo -m 0600 "$PASEO_KIT/templates/paseo-config.json" /srv/paseo/.paseo/config.json

if ! IFS= read -r -p '输入主 API 供应商地址（HTTPS，可省略末尾 /v1）： ' base_url </dev/tty; then
  echo '无法从当前终端读取主 API 供应商地址；未启动服务。' >&2
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
  echo '主 API 供应商地址必须是 https:// URL。' >&2
  exit 1
fi
while [[ "$base_url" == */ ]]; do base_url="${base_url%/}"; done
[[ "$base_url" == */v1 ]] || base_url="$base_url/v1"

BASE_URL="$base_url" python3 - /srv/paseo/.codex/config.toml <<'PY'
import json
import os
import re
import stat
import sys
import tempfile
import tomllib
from pathlib import Path

path = Path(sys.argv[1])
base_url = os.environ['BASE_URL']
original = path.stat()
lines = path.read_text().splitlines(keepends=True)
section_name = '[model_providers.hahaapi]'
section_start = next((i for i, line in enumerate(lines) if line.strip() == section_name), None)
if section_start is None:
    raise SystemExit('Codex 配置缺少 [model_providers.hahaapi]；未启动服务。')

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
echo '主 API 供应商地址已写入 Codex 配置（已确保使用 /v1）。'

# Generate the helper profile only when absent; never replace a user's existing profile.
if [[ ! -e /srv/paseo/.profile ]]; then
  python3 - <<'PY'
import shlex
from pathlib import Path
lines = Path('/etc/paseo/runtime.env').read_text().splitlines()
profile = ['# Paseo v3.3 project environment; credentials are intentionally absent.']
for line in lines:
    if not line or line.startswith('#'):
        continue
    key, value = line.split('=', 1)
    profile.append(f'export {key}={shlex.quote(value)}')
Path('/srv/paseo/.profile').write_text('\n'.join(profile) + '\n')
PY
  chown paseo:paseo /srv/paseo/.profile
  chmod 0600 /srv/paseo/.profile
fi

# Validate required non-secret config before starting; preserve unknown user fields.
python3 - <<'PY'
import json
from pathlib import Path
p = Path('/srv/paseo/.paseo/config.json')
c = json.loads(p.read_text())
assert c['daemon']['listen'] == '127.0.0.1:6767', 'daemon.listen 必须为 127.0.0.1:6767'
assert c['daemon']['relay']['enabled'] is True, 'daemon.relay.enabled 必须为 true'
assert c['daemon']['relay'].get('useTls') is True, 'daemon.relay.useTls 必须为 true'
assert c['daemon']['relay'].get('publicUseTls') is True, 'daemon.relay.publicUseTls 必须为 true'
print('非机密 Paseo 配置检查通过。')
PY

if [[ ! -e "$PASEO_ETC/hahaapi.env" ]]; then
  python3 - <<'PY'
import getpass, os, warnings
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
  owner="$(stat -c '%U:%G %a' "$PASEO_ETC/hahaapi.env")"
  echo "保留已有 API key 文件（当前权限：$owner）"
  [[ "$(stat -c '%u:%g %a' "$PASEO_ETC/hahaapi.env")" == '0:0 600' ]] || {
    echo 'API key 文件必须是 root:root、0600；已停止，未修改 key 内容。' >&2
    exit 1
  }
  python3 - <<'PY'
from pathlib import Path
text = Path('/etc/paseo/hahaapi.env').read_text()
assert any(line.startswith('HAHA_API_KEY=') and len(line.split('=', 1)[1].strip()) > 2 for line in text.splitlines()), 'API key 文件没有非空 HAHA_API_KEY；未启动服务。'
PY
fi

auth_state="$(python3 - <<'PY'
import json
from pathlib import Path
c = json.loads(Path('/srv/paseo/.paseo/config.json').read_text())
print('set' if c.get('daemon', {}).get('auth', {}).get('password') else 'missing')
PY
)"
if [[ "$auth_state" == missing ]]; then
  echo '现在设置 Paseo 本机管理密码（不是 API key），按提示输入两次。'
  runuser -u paseo -- env -i HOME=/srv/paseo PATH="$PASEO_RUNTIME_PATH" \
    PASEO_HOME=/srv/paseo/.paseo "$PASEO_ROOT/apps/node_modules/.bin/paseo" \
    daemon set-password </dev/tty
else
  echo '保留已有 Paseo 本机管理密码哈希，不重复询问。'
fi

# This unit is owned by v3.3; a rerun refreshes it to the package template.
install -o root -g root -m 0644 "$PASEO_KIT/templates/paseo.service" /etc/systemd/system/paseo.service
systemctl daemon-reload
systemctl enable paseo.service
systemctl restart paseo.service

if python3 "$PASEO_KIT/lib/local-check.py" --wait; then
  install -o root -g root -m 0644 /dev/null "$PASEO_ETC/.configured"
  echo 'STEP2_OK：后端已正确运行，Relay 配置已启用；可重复执行。'
else
  systemctl --no-pager --full status paseo.service || true
  journalctl -u paseo.service -n 40 --no-pager
  exit 1
fi
