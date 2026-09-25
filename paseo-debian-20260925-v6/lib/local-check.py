#!/usr/bin/env python3
"""Verify the installed runtime, service boundary, configuration and secrets."""
import json
import os
import pwd
import re
import stat
import subprocess
import sys
import time
import tomllib
import urllib.request
from pathlib import Path

EXPECTED = {
    "node": "26.10.0",
    "npm": "11.19.1",
    "paseo": "0.9.2",
    "codex": "0.157.0",
    "uv": "0.12.19",
}
EXPECTED_RELEASE = "paseo-debian-20260925-v6"
RUNTIME = Path("/srv/paseo/runtime")
PASEO_HOME = Path("/srv/paseo/.paseo")
CODEX_HOME = Path("/srv/paseo/.codex")
RUNTIME_PATH = (
    f"{RUNTIME}/apps/node_modules/.bin:{RUNTIME}/node/bin:{RUNTIME}/uv/bin:"
    "/srv/paseo/tools/bin:/srv/paseo/tools/cargo/bin:/srv/paseo/tools/go/bin:"
    "/usr/local/bin:/usr/bin:/bin"
)
CACHE_DIRS = (
    "/srv/paseo/cache",
    "/srv/paseo/cache/tmp",
    "/srv/paseo/cache/npm-paseo",
    "/srv/paseo/cache/pip",
    "/srv/paseo/cache/uv",
    "/srv/paseo/cache/gomod",
    "/srv/paseo/cache/go-build",
    "/srv/paseo/cache/ms-playwright",
)


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=12).strip()


def assert_owner_mode(path, owner, group, mode):
    info = Path(path).stat()
    expected_uid = pwd.getpwnam(owner).pw_uid if isinstance(owner, str) else owner
    expected_gid = pwd.getpwnam(group).pw_gid if isinstance(group, str) else group
    assert (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (
        expected_uid,
        expected_gid,
        mode,
    ), f"权限或属主异常：{path}"


def run_as_paseo(*args):
    return run(
        "runuser",
        "-u",
        "paseo",
        "--",
        "env",
        "-i",
        "HOME=/srv/paseo",
        "CODEX_HOME=/srv/paseo/.codex",
        "PASEO_HOME=/srv/paseo/.paseo",
        f"PATH={RUNTIME_PATH}",
        *args,
    )


def check_once():
    props = dict(
        line.split("=", 1)
        for line in run(
            "systemctl",
            "--no-pager",
            "show",
            "paseo.service",
            "-p",
            "ActiveState",
            "-p",
            "User",
            "-p",
            "Group",
            "-p",
            "WorkingDirectory",
            "-p",
            "FragmentPath",
            "-p",
            "DropInPaths",
        ).splitlines()
    )
    assert props.get("ActiveState") == "active", "Paseo service is not active"
    assert props.get("User") == "paseo" and props.get("Group") == "paseo", "Service user/group mismatch"
    assert props.get("WorkingDirectory") == "/srv/proj", "Service working directory mismatch"
    assert props.get("FragmentPath") == "/etc/systemd/system/paseo.service", "Unexpected systemd unit path"
    run("runuser", "-u", "paseo", "--", "test", "-w", "/srv/proj")

    unit_path = Path("/etc/systemd/system/paseo.service")
    unit = unit_path.read_text()
    assert_owner_mode(unit_path, 0, 0, 0o644)
    run("systemd-analyze", "verify", str(unit_path))
    for required in (
        "User=paseo",
        "Group=paseo",
        "WorkingDirectory=/srv/proj",
        "EnvironmentFile=/etc/paseo/runtime.env",
        "EnvironmentFile=/etc/paseo/hahaapi.env",
        "/srv/paseo/runtime/node/bin/node /srv/paseo/runtime/apps/node_modules/@getpaseo/cli/bin/paseo daemon run --home /srv/paseo/.paseo",
        "NoNewPrivileges=true",
        "ProtectSystem=strict",
        "ProtectHome=true",
    ):
        assert required in unit, f"systemd unit 缺少当前部署项：{required}"

    env_path = Path("/etc/paseo/runtime.env")
    assert_owner_mode(env_path, 0, 0, 0o644)
    service_env = dict(
        line.split("=", 1)
        for line in env_path.read_text().splitlines()
        if line and not line.startswith("#")
    )
    assert service_env.get("HOME") == "/srv/paseo"
    assert service_env.get("CODEX_HOME") == str(CODEX_HOME)
    assert service_env.get("PASEO_HOME") == str(PASEO_HOME)
    assert service_env.get("TMPDIR") == "/srv/paseo/cache/tmp"
    assert service_env.get("XDG_CACHE_HOME") == "/srv/paseo/cache"
    assert service_env.get("npm_config_cache") == "/srv/paseo/cache/npm-paseo"
    assert service_env.get("npm_config_prefix") == "/srv/paseo/tools"
    assert service_env.get("UV_CACHE_DIR") == "/srv/paseo/cache/uv"
    assert service_env.get("UV_PYTHON_INSTALL_DIR") == "/srv/paseo/tools/python"
    assert service_env.get("UV_TOOL_DIR") == "/srv/paseo/tools/uv"
    assert service_env.get("UV_TOOL_BIN_DIR") == "/srv/paseo/tools/bin"
    assert service_env.get("PIP_CACHE_DIR") == "/srv/paseo/cache/pip"
    assert service_env.get("CARGO_HOME") == "/srv/paseo/tools/cargo"
    assert service_env.get("RUSTUP_HOME") == "/srv/paseo/tools/rustup"
    assert service_env.get("GOPATH") == "/srv/paseo/tools/go"
    assert service_env.get("GOMODCACHE") == "/srv/paseo/cache/gomod"
    assert service_env.get("GOCACHE") == "/srv/paseo/cache/go-build"
    assert service_env.get("PLAYWRIGHT_BROWSERS_PATH") == "/srv/paseo/cache/ms-playwright"
    for path in (
        f"{RUNTIME}/apps/node_modules/.bin",
        f"{RUNTIME}/node/bin",
        f"{RUNTIME}/uv/bin",
        "/srv/paseo/tools/bin",
    ):
        assert path in service_env.get("PATH", ""), f"PATH 缺少运行时目录：{path}"
    assert not any("API_KEY" in name for name in service_env), "运行时模板不得存放 API key"

    assert_owner_mode("/etc/paseo", 0, 0, 0o700)
    assert_owner_mode(RUNTIME, 0, 0, 0o755)
    assert_owner_mode(PASEO_HOME, "paseo", "paseo", 0o700)
    assert_owner_mode(CODEX_HOME, "paseo", "paseo", 0o700)
    assert_owner_mode("/srv/proj", "paseo", "paseo", 0o700)
    assert_owner_mode("/srv/paseo/worktrees", "paseo", "paseo", 0o700)
    assert_owner_mode("/srv/paseo/tools", "paseo", "paseo", 0o700)
    assert_owner_mode("/srv/paseo/tools/bin", "paseo", "paseo", 0o700)
    for path in CACHE_DIRS:
        assert_owner_mode(path, "paseo", "paseo", 0o700)
    profile = Path("/srv/paseo/.profile")
    assert_owner_mode(profile, "paseo", "paseo", 0o600)
    assert "API_KEY" not in profile.read_text(), "用户 profile 不得包含 API key"
    assert_owner_mode(CODEX_HOME / "config.toml", "paseo", "paseo", 0o600)
    assert_owner_mode(PASEO_HOME / "config.json", "paseo", "paseo", 0o600)

    install_state = dict(
        line.split("=", 1)
        for line in (RUNTIME / ".install-complete").read_text().splitlines()
        if "=" in line
    )
    assert install_state.get("package") == EXPECTED_RELEASE, "安装记录发行包错误"
    for key, value in EXPECTED.items():
        assert install_state.get(key) == value, f"安装记录版本错误：{key}"
    package = json.loads((RUNTIME / "apps/package.json").read_text())
    lock = json.loads((RUNTIME / "apps/package-lock.json").read_text())
    assert package["dependencies"] == {
        "@getpaseo/cli": EXPECTED["paseo"],
        "@openai/codex": EXPECTED["codex"],
    }
    assert package["allowScripts"] == {
        "esbuild@0.25.12": True,
        "node-pty@1.2.0-beta.15": True,
    }
    assert package["overrides"] == {
        "ai": "5.0.207",
        "linkify-it": "6.1.0",
        "markdown-it": "15.0.2",
        "uuid": "14.0.2",
    }
    assert lock["packages"][""]["dependencies"] == package["dependencies"]
    assert json.loads((RUNTIME / "apps/node_modules/@getpaseo/cli/package.json").read_text())["version"] == EXPECTED["paseo"]
    assert json.loads((RUNTIME / "apps/node_modules/@openai/codex/package.json").read_text())["version"] == EXPECTED["codex"]
    assert json.loads((RUNTIME / "apps/node_modules/ai/package.json").read_text())["version"] == "5.0.207"
    assert json.loads((RUNTIME / "apps/node_modules/@ai-sdk/gateway/package.json").read_text())["version"] == "2.0.106"
    assert json.loads((RUNTIME / "apps/node_modules/@ai-sdk/provider-utils/package.json").read_text())["version"] == "3.0.28"

    versions = {
        "node": run_as_paseo(f"{RUNTIME}/node/bin/node", "--version"),
        "npm": run_as_paseo(f"{RUNTIME}/node/bin/npm", "--version"),
        "paseo": run_as_paseo(f"{RUNTIME}/apps/node_modules/.bin/paseo", "--version"),
        "codex": run_as_paseo(f"{RUNTIME}/apps/node_modules/.bin/codex", "--version"),
        "uv": run_as_paseo(f"{RUNTIME}/uv/bin/uv", "--version"),
    }
    assert versions["node"] == f"v{EXPECTED['node']}"
    assert versions["npm"] == EXPECTED["npm"]
    assert EXPECTED["paseo"] in versions["paseo"]
    assert versions["codex"] == f"codex-cli {EXPECTED['codex']}"
    assert versions["uv"].startswith(f"uv {EXPECTED['uv']} ")
    run_as_paseo(f"{RUNTIME}/apps/node_modules/.bin/codex", "--strict-config", "--help")
    run_as_paseo(f"{RUNTIME}/apps/node_modules/.bin/codex", "app-server", "--help")

    listeners = run("ss", "-H", "-lnt", "sport = :6767").splitlines()
    assert listeners and all(line.split()[3] == "127.0.0.1:6767" for line in listeners), "6767 must only listen on 127.0.0.1"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open("http://127.0.0.1:6767/api/health", timeout=3) as response:
        assert response.status == 200
        json.loads(response.read())

    config = json.loads((PASEO_HOME / "config.json").read_text())
    assert config.get("$schema") == "https://paseo.sh/schemas/paseo.config.v1.json"
    daemon = config["daemon"]
    assert daemon["listen"] == "127.0.0.1:6767"
    assert daemon.get("auth", {}).get("password"), "Paseo 管理密码缺失"
    assert daemon["relay"]["enabled"] and daemon["relay"]["useTls"] and daemon["relay"]["publicUseTls"]
    assert daemon["hostnames"] == ["localhost", "127.0.0.1"]
    assert config["features"]["webUi"]["enabled"] is False
    assert config["agents"]["providers"]["codex"]["enabled"] is True
    assert config["agents"]["providers"]["codex"]["models"][0]["id"] == "gpt-6-astra"
    assert config["agents"]["metadataGeneration"]["providers"] == [
        {"provider": "codex", "model": "gpt-6-astra", "thinkingOptionId": "high"}
    ]
    for item in ("dictation", "voiceMode"):
        assert config["features"][item]["enabled"] is False

    codex_config = tomllib.loads((CODEX_HOME / "config.toml").read_text())
    assert codex_config["model"] == "gpt-6-astra"
    assert codex_config["model_provider"] == "hahaapi"
    assert codex_config["model_providers"]["hahaapi"]["wire_api"] == "responses"
    assert codex_config["model_providers"]["hahaapi"]["env_key"] == "HAHA_API_KEY"
    env_filters = codex_config["shell_environment_policy"]["filters"]
    assert env_filters.get("HAHA_API_KEY") == "exclude"
    assert env_filters.get("BACKAPI_API_KEY") == "exclude"
    assert env_filters.get("OPENAI_API_KEY") == "exclude"

    secret = Path("/etc/paseo/hahaapi.env")
    assert_owner_mode(secret, 0, 0, 0o600)
    secret_text = secret.read_text()
    assert any(line.startswith("HAHA_API_KEY=") and len(line.split("=", 1)[1].strip()) > 2 for line in secret_text.splitlines()), "HAHA_API_KEY 为空"

    backapi = Path("/etc/paseo/backapi.env")
    provider = config.get("agents", {}).get("providers", {}).get("codex-bk")
    if backapi.exists():
        assert_owner_mode(backapi, 0, 0, 0o600)
        backapi_text = backapi.read_text()
        assert any(line.startswith("BACKAPI_API_KEY=") and len(line.split("=", 1)[1].strip()) > 2 for line in backapi_text.splitlines()), "BACKAPI_API_KEY 为空"
        assert provider and provider.get("extends") == "codex" and provider.get("enabled") is True, "BackAPI provider 配置缺失"
        assert provider.get("command") == ["/srv/paseo/runtime/apps/backapi-codex-wrapper"], "BackAPI wrapper 路径异常"
        wrapper = Path("/srv/paseo/runtime/apps/backapi-codex-wrapper")
        assert wrapper.is_file() and wrapper.stat().st_mode & 0o111, "BackAPI wrapper 不可执行"
        dropin = Path("/etc/systemd/system/paseo.service.d/10-backapi.conf")
        assert_owner_mode(dropin, 0, 0, 0o644)
        assert "EnvironmentFile=-/etc/paseo/backapi.env" in dropin.read_text()
        assert str(dropin) in props.get("DropInPaths", "").split(), "BackAPI systemd drop-in 未加载"
        assert env_filters.get("BACKAPI_API_KEY") == "exclude"
        assert env_filters.get("OPENAI_API_KEY") == "exclude"
    else:
        assert provider is None, "BackAPI provider exists but secret file is missing"
        assert "/etc/systemd/system/paseo.service.d/10-backapi.conf" not in props.get("DropInPaths", "").split(), "没有 BackAPI 密钥时不应加载 BackAPI systemd drop-in"


seconds = 60 if "--wait" in sys.argv else 0
deadline = time.monotonic() + seconds
while True:
    try:
        check_once()
        print("LOCAL_OK：组件版本、paseo 用户、systemd、路径权限、回环监听、health 与配置检查通过。")
        break
    except Exception:
        if time.monotonic() >= deadline:
            print("LOCAL_CHECK_FAILED：本机部署验收未通过；检查 systemctl status 与 journalctl，勿输出密钥。", file=sys.stderr)
            sys.exit(1)
        time.sleep(2)
