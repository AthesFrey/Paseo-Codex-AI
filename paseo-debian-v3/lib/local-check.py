#!/usr/bin/env python3
"""Check live service/listener/HTTP and private file facts, not API credentials."""
import json, os, stat, subprocess, sys, time, urllib.request
from pathlib import Path

def run(*args):
    return subprocess.check_output(args, text=True, timeout=8).strip()

def check_once():
    props = dict(line.split('=',1) for line in run('systemctl','--no-pager','show','paseo.service','-p','ActiveState','-p','User').splitlines())
    assert props.get('ActiveState') == 'active' and props.get('User') == 'paseo', '服务未以 paseo 用户 active 运行'
    listeners = run('ss','-H','-lnt','sport = :6767').splitlines()
    assert listeners and all(line.split()[3] == '127.0.0.1:6767' for line in listeners), '6767 没有监听在唯一的回环地址'
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open('http://127.0.0.1:6767/api/health',timeout=3) as resp:
        assert resp.status == 200
        json.loads(resp.read())
    config = json.loads(Path('/srv/paseo/.paseo/config.json').read_text())
    daemon = config['daemon']
    assert daemon['listen'] == '127.0.0.1:6767'
    assert daemon.get('auth',{}).get('password'), '本机管理密码缺失'
    assert daemon['relay']['enabled'] and daemon['relay']['useTls'] and daemon['relay']['publicUseTls']
    for item in ('dictation','voiceMode'):
        assert config['features'][item]['enabled'] is False
    secret = Path('/etc/paseo-v3/hahaapi.env').stat()
    assert secret.st_uid == 0 and secret.st_gid == 0 and stat.S_IMODE(secret.st_mode) == 0o600 and secret.st_size > 16, 'API key 文件权限/大小异常'
    secret_text = Path('/etc/paseo-v3/hahaapi.env').read_text()
    assert any(line.startswith('HAHA_API_KEY=') and len(line.split('=', 1)[1].strip()) > 2 for line in secret_text.splitlines()), 'HAHA_API_KEY 为空'

seconds = 60 if '--wait' in sys.argv else 0
deadline=time.monotonic()+seconds
while True:
    try:
        check_once()
        print('LOCAL_OK：paseo 用户运行，唯一回环监听 127.0.0.1:6767，health 与配置检查通过。')
        break
    except Exception:
        if time.monotonic() >= deadline:
            print('LOCAL_CHECK_FAILED：服务、监听或配置检查未通过；执行 systemctl --no-pager --full status paseo。',file=sys.stderr)
            sys.exit(1)
        time.sleep(2)
