#!/usr/bin/env python3
"""Verify the v6.1fix2 runtime, current Paseo config, service boundary and secrets."""
from __future__ import annotations

import hashlib
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

EXPECTED_RELEASE = "paseo-debian-20261002-v6.1fix2"
PACKAGE_VERSION = "2026.10.2-v6.1fix2"
RUNTIME = Path("/srv/paseo/runtime")
PASEO_HOME = Path("/srv/paseo/.paseo")
CODEX_HOME = Path("/srv/paseo/.codex")
CODEX_BIN = Path("/srv/paseo/tools/bin/codex")
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


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=20).strip()


def run_as_paseo(*args: str) -> str:
    # Set cwd explicitly.  The official Codex installer and some Node cleanup
    # paths restore their initial cwd; inheriting /root breaks for paseo.
    return subprocess.check_output(
        (
            "runuser",
            "-u",
            "paseo",
            "--",
            "env",
            "-i",
            "HOME=/srv/paseo",
            "USER=paseo",
            "LOGNAME=paseo",
            "SHELL=/bin/bash",
            "CODEX_HOME=/srv/paseo/.codex",
            "PASEO_HOME=/srv/paseo/.paseo",
            "TMPDIR=/srv/paseo/cache/tmp",
            "XDG_CACHE_HOME=/srv/paseo/cache",
            "npm_config_cache=/srv/paseo/cache/npm-paseo",
            "npm_config_prefix=/srv/paseo/tools",
            "npm_config_userconfig=/dev/null",
            "npm_config_registry=https://registry.npmjs.org/",
            f"PATH={RUNTIME_PATH}",
            *args,
        ),
        text=True,
        stderr=subprocess.DEVNULL,
        cwd="/srv/proj",
        timeout=20,
    ).strip()


def assert_owner_mode(path: Path | str, owner: int | str, group: int | str, mode: int) -> None:
    path = Path(path)
    info = path.stat()
    expected_uid = pwd.getpwnam(owner).pw_uid if isinstance(owner, str) else owner
    expected_gid = pwd.getpwnam(group).pw_gid if isinstance(group, str) else group
    assert (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (
        expected_uid,
        expected_gid,
        mode,
    ), f"权限或属主异常：{path}"


def read_install_state() -> dict[str, str]:
    path = RUNTIME / ".install-complete"
    assert_owner_mode(path, 0, 0, 0o644)
    state: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        assert separator and key and value and "\n" not in value and "\r" not in value
        state[key] = value
    assert state.get("package") == EXPECTED_RELEASE, "安装记录发行包错误"
    for key in ("node", "npm", "paseo", "codex", "uv"):
        assert state.get(key), f"安装记录缺少版本：{key}"
    assert state.get("codex_home") == str(CODEX_HOME)
    assert state.get("codex_bin") == str(CODEX_BIN)
    for key in ("node_source", "npm_source", "paseo_source", "codex_source", "uv_source"):
        assert state.get(key, "").startswith("https://")
    for key in ("node_sha256", "codex_installer_sha256", "codex_binary_sha256", "uv_sha256"):
        assert re.fullmatch(r"[0-9a-f]{64}", state.get(key, "")), f"安装记录校验值错误：{key}"
    assert state.get("npm_integrity", "").startswith("sha512-")
    assert state.get("paseo_integrity", "").startswith("sha512-")
    native = state.get("native_packages", "")
    assert native and all("@" in item for item in native.split(",")), "安装记录缺少 native 依赖"
    return state


def parse_environment(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        assert separator and key and "API_KEY" not in key and "PASSWORD" not in key
        result[key] = value
    return result


def assert_secret(path: Path, name: str) -> None:
    assert_owner_mode(path, 0, 0, 0o600)
    text = path.read_text(encoding="utf-8")
    values = [line.split("=", 1)[1].strip() for line in text.splitlines() if line.startswith(f"{name}=")]
    assert len(values) == 1 and len(values[0]) > 2, f"{name} 缺失或为空"
    assert "\n" not in values[0] and "\r" not in values[0]


THINKING_OPTION_IDS = ["low", "medium", "high", "xhigh", "max"]


def assert_model_catalog(provider: dict, label: str) -> str:
    models = provider.get("models")
    assert isinstance(models, list) and models, f"{label} 模型列表为空"
    ids = [model.get("id") for model in models]
    assert all(isinstance(model_id, str) and model_id for model_id in ids), f"{label} 模型 ID 无效"
    assert len(ids) == len(set(ids)), f"{label} 模型 ID 重复"
    defaults = [model for model in models if model.get("isDefault") is True]
    assert len(defaults) == 1, f"{label} 必须恰好有一个默认模型"
    for model in models:
        assert isinstance(model.get("label"), str) and model["label"], f"{label} 模型标签缺失"
        options = model.get("thinkingOptions")
        assert isinstance(options, list), f"{label} thinking options 缺失"
        assert [option.get("id") for option in options] == THINKING_OPTION_IDS
        assert sum(option.get("isDefault") is True for option in options) == 1
        assert next(option["id"] for option in options if option.get("isDefault")) == "high"
    return defaults[0]["id"]


def check_once() -> None:
    assert os.geteuid() == 0, "本地验收必须由 root 执行"
    state = read_install_state()

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

    unit_path = Path("/etc/systemd/system/paseo.service")
    unit = unit_path.read_text(encoding="utf-8")
    assert_owner_mode(unit_path, 0, 0, 0o644)
    run("systemd-analyze", "verify", str(unit_path))
    for required in (
        "Description=Paseo Relay daemon (paseo-debian-20261002-v6.1fix2)",
        "User=paseo",
        "Group=paseo",
        "WorkingDirectory=/srv/proj",
        "EnvironmentFile=/etc/paseo/runtime.env",
        "EnvironmentFile=/etc/paseo/hahaapi.env",
        "/srv/paseo/runtime/node/bin/node /srv/paseo/runtime/apps/node_modules/@getpaseo/cli/bin/paseo daemon run --home /srv/paseo/.paseo",
        "NoNewPrivileges=true",
        "ProtectSystem=strict",
        "ProtectHome=true",
        "PrivateTmp=true",
    ):
        assert required in unit, f"systemd unit 缺少当前部署项：{required}"
    assert "docker run" not in unit.lower() and "docker exec" not in unit.lower()

    env_path = Path("/etc/paseo/runtime.env")
    assert_owner_mode(env_path, 0, 0, 0o644)
    service_env = parse_environment(env_path)
    expected_env = {
        "HOME": "/srv/paseo",
        "CODEX_HOME": str(CODEX_HOME),
        "PASEO_HOME": str(PASEO_HOME),
        "TMPDIR": "/srv/paseo/cache/tmp",
        "XDG_CACHE_HOME": "/srv/paseo/cache",
        "npm_config_cache": "/srv/paseo/cache/npm-paseo",
        "npm_config_prefix": "/srv/paseo/tools",
        "UV_CACHE_DIR": "/srv/paseo/cache/uv",
        "UV_PYTHON_INSTALL_DIR": "/srv/paseo/tools/python",
        "UV_TOOL_DIR": "/srv/paseo/tools/uv",
        "UV_TOOL_BIN_DIR": "/srv/paseo/tools/bin",
        "PIP_CACHE_DIR": "/srv/paseo/cache/pip",
        "CARGO_HOME": "/srv/paseo/tools/cargo",
        "RUSTUP_HOME": "/srv/paseo/tools/rustup",
        "GOPATH": "/srv/paseo/tools/go",
        "GOMODCACHE": "/srv/paseo/cache/gomod",
        "GOCACHE": "/srv/paseo/cache/go-build",
        "PLAYWRIGHT_BROWSERS_PATH": "/srv/paseo/cache/ms-playwright",
    }
    for key, value in expected_env.items():
        assert service_env.get(key) == value, f"runtime.env 缺少或错误：{key}"
    for path in (f"{RUNTIME}/apps/node_modules/.bin", f"{RUNTIME}/node/bin", f"{RUNTIME}/uv/bin", "/srv/paseo/tools/bin"):
        assert path in service_env.get("PATH", ""), f"PATH 缺少运行时目录：{path}"
    assert not any("API_KEY" in name or "PASSWORD" in name for name in service_env)

    assert_owner_mode("/etc/paseo", 0, 0, 0o700)
    assert_owner_mode(RUNTIME, 0, 0, 0o755)
    assert_owner_mode(PASEO_HOME, "paseo", "paseo", 0o700)
    assert_owner_mode(CODEX_HOME, "paseo", "paseo", 0o700)
    assert_owner_mode("/srv/paseo/worktrees", "paseo", "paseo", 0o700)
    assert_owner_mode("/srv/paseo/tools", "paseo", "paseo", 0o700)
    assert_owner_mode("/srv/paseo/tools/bin", "paseo", "paseo", 0o700)
    for path in CACHE_DIRS:
        assert_owner_mode(path, "paseo", "paseo", 0o700)
    run_as_paseo("/usr/bin/test", "-x", "/srv/proj")
    profile = Path("/srv/paseo/.profile")
    assert_owner_mode(profile, "paseo", "paseo", 0o600)
    assert "API_KEY" not in profile.read_text(encoding="utf-8")
    assert_owner_mode(CODEX_HOME / "config.toml", "paseo", "paseo", 0o600)
    assert_owner_mode(PASEO_HOME / "config.json", "paseo", "paseo", 0o600)

    package_path = RUNTIME / "apps/package.json"
    lock_path = RUNTIME / "apps/package-lock.json"
    package = json.loads(package_path.read_text(encoding="utf-8"))
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    assert package["version"] == PACKAGE_VERSION
    assert package["dependencies"] == {"@getpaseo/cli": "latest"}
    assert lock["packages"][""]["dependencies"] == {"@getpaseo/cli": "latest"}
    package_text = package_path.read_text(encoding="utf-8")
    lock_text = lock_path.read_text(encoding="utf-8")
    assert "@openai/codex" not in package_text and "@openai/codex" not in lock_text
    assert not (RUNTIME / "apps/node_modules/@openai/codex").exists()
    paseo_package = json.loads((RUNTIME / "apps/node_modules/@getpaseo/cli/package.json").read_text(encoding="utf-8"))
    assert paseo_package["version"] == state["paseo"]
    assert not (RUNTIME / "apps/.npmrc").exists()
    for item in state["native_packages"].split(","):
        package, version = item.rsplit("@", 1)
        package_path = RUNTIME / "apps/node_modules" / package
        assert package_path.is_dir(), f"native 依赖缺失：{package}"
        package_meta = json.loads((package_path / "package.json").read_text(encoding="utf-8"))
        assert package_meta.get("version") == version, f"native 依赖版本不一致：{package}"

    versions = {
        "node": run_as_paseo(f"{RUNTIME}/node/bin/node", "--version"),
        "npm": run_as_paseo(f"{RUNTIME}/node/bin/npm", "--version"),
        "paseo": run_as_paseo(f"{RUNTIME}/apps/node_modules/.bin/paseo", "--version"),
        "codex": run_as_paseo(str(CODEX_BIN), "--version"),
        "uv": run_as_paseo(f"{RUNTIME}/uv/bin/uv", "--version"),
    }
    assert versions["node"] == f"v{state['node']}"
    assert versions["npm"] == state["npm"]
    assert state["paseo"] in versions["paseo"]
    assert versions["codex"] == f"codex-cli {state['codex']}"
    assert versions["uv"].startswith(f"uv {state['uv']} ")

    assert CODEX_BIN.is_symlink()
    codex_target = CODEX_BIN.resolve()
    assert str(codex_target).startswith(str(CODEX_HOME / "packages/standalone"))
    digest = hashlib.sha256(codex_target.read_bytes()).hexdigest()
    assert digest == state["codex_binary_sha256"], "Codex standalone 二进制校验值与安装记录不一致"
    current = CODEX_HOME / "packages/standalone/current"
    assert current.is_symlink() and current.resolve() == codex_target.parent.parent
    codex_release = current.resolve()
    assert (codex_release / "bin/codex").is_file()
    assert codex_release.name.startswith(f"{state['codex']}-")
    run_as_paseo(str(CODEX_BIN), "--strict-config", "--help")
    run_as_paseo(str(CODEX_BIN), "app-server", "--help")

    # Ask the installed current CLI to parse config.json again before checking
    # its JSON fields; this catches strict-schema errors early.
    run_as_paseo(f"{RUNTIME}/apps/node_modules/.bin/paseo", "daemon", "config", "get", "--home", str(PASEO_HOME))

    listeners = run("ss", "-H", "-lnt", "sport = :6767").splitlines()
    assert listeners and all(line.split()[3] == "127.0.0.1:6767" for line in listeners), "6767 must only listen on 127.0.0.1"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open("http://127.0.0.1:6767/api/health", timeout=3) as response:
        assert response.status == 200
        json.loads(response.read())

    config = json.loads((PASEO_HOME / "config.json").read_text(encoding="utf-8"))
    assert config.get("$schema") == "https://paseo.sh/schemas/paseo.config.v1.json"
    assert config.get("version") == 1
    daemon = config["daemon"]
    assert daemon["listen"] == "127.0.0.1:6767"
    assert daemon.get("auth", {}).get("password"), "Paseo 管理密码缺失"
    assert daemon["relay"]["enabled"] and daemon["relay"]["useTls"] and daemon["relay"]["publicUseTls"]
    assert daemon.get("hostnames") == ["localhost", "127.0.0.1"]
    assert config["worktrees"]["root"] == "/srv/paseo/worktrees"
    assert config["features"]["webUi"]["enabled"] is False
    assert config["features"]["dictation"]["enabled"] is False
    assert config["features"]["voiceMode"]["enabled"] is False
    codex_provider = config["agents"]["providers"]["codex"]
    assert codex_provider["enabled"] is True
    primary_default = assert_model_catalog(codex_provider, "主 API")
    assert config["agents"]["metadataGeneration"]["providers"] == [
        {"provider": "codex", "model": primary_default, "thinkingOptionId": "high"}
    ]

    codex_config = tomllib.loads((CODEX_HOME / "config.toml").read_text(encoding="utf-8"))
    assert codex_config["model"] == primary_default
    assert codex_config["model_provider"] == "hahaapi"
    assert codex_config["model_providers"]["hahaapi"]["wire_api"] == "responses"
    assert codex_config["model_providers"]["hahaapi"]["env_key"] == "HAHA_API_KEY"
    assert codex_config["model_providers"]["hahaapi"]["base_url"].startswith("https://")
    env_filters = codex_config["shell_environment_policy"]["filters"]
    assert env_filters.get("HAHA_API_KEY") == "exclude"
    assert env_filters.get("BACKAPI_API_KEY") == "exclude"
    assert env_filters.get("OPENAI_API_KEY") == "exclude"

    assert_secret(Path("/etc/paseo/hahaapi.env"), "HAHA_API_KEY")
    backapi = Path("/etc/paseo/backapi.env")
    provider = config.get("agents", {}).get("providers", {}).get("codex-bk")
    if backapi.exists():
        assert_secret(backapi, "BACKAPI_API_KEY")
        assert provider and provider.get("extends") == "codex" and provider.get("enabled") is True
        assert_model_catalog(provider, "BackAPI")
        wrapper = Path("/srv/paseo/runtime/apps/backapi-codex-wrapper")
        assert provider.get("command") == [str(wrapper)]
        assert provider.get("env", {}).get("OPENAI_API_KEY") == "__paseo_backapi_wrapper__"
        assert wrapper.is_file() and wrapper.stat().st_mode & 0o111
        wrapper_text = wrapper.read_text(encoding="utf-8")
        assert "/srv/paseo/tools/bin/codex" in wrapper_text
        assert "BACKAPI_API_KEY" in wrapper_text and "OPENAI_API_KEY" in wrapper_text
        assert "export OPENAI_API_KEY=\"$BACKAPI_API_KEY\"" in wrapper_text
        dropin = Path("/etc/systemd/system/paseo.service.d/10-backapi.conf")
        assert_owner_mode(dropin, 0, 0, 0o644)
        assert "EnvironmentFile=-/etc/paseo/backapi.env" in dropin.read_text(encoding="utf-8")
        assert str(dropin) in props.get("DropInPaths", "").split()
    else:
        assert provider is None
        assert "/etc/systemd/system/paseo.service.d/10-backapi.conf" not in props.get("DropInPaths", "").split()

    kit_root = Path(__file__).resolve().parents[1]
    for path in list(kit_root.glob("*.sh")) + list((kit_root / "templates").glob("*.service")):
        text = path.read_text(encoding="utf-8").lower()
        assert "docker exec" not in text and "docker run" not in text


seconds = 60 if "--wait" in sys.argv else 0
deadline = time.monotonic() + seconds
while True:
    try:
        check_once()
        print("LOCAL_OK：组件版本、npm latest、standalone Codex、paseo 用户、systemd、路径权限、回环监听、health 与当前配置检查通过。")
        break
    except Exception:
        if time.monotonic() >= deadline:
            print("LOCAL_CHECK_FAILED：本机部署验收未通过；检查 systemctl status 与 journalctl，勿输出密钥。", file=sys.stderr)
            sys.exit(1)
        time.sleep(2)
