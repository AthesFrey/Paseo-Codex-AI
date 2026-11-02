#!/usr/bin/env python3
"""Check Codex and Claude provider configuration without live API calls."""
from __future__ import annotations

import importlib.util
import json
import os
import pty
import select
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import tomllib
import unittest
from pathlib import Path


KIT = Path(__file__).resolve().parents[1]
GENERATOR = KIT / "lib/apply-model-config.py"
SELECTOR = KIT / "lib/model-selector.py"
TEMPLATES = KIT / "templates"
CLAUDE_URL = "https://sub2.hahaapi.com"
MAIN_URL = "https://codex.example.test/v1"
TEST_KEY = "test-anthropic-key-never-log"

spec = importlib.util.spec_from_file_location("model_selector", SELECTOR)
assert spec and spec.loader
model_selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(model_selector)


class ProviderConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="paseo-provider-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.paseo_home = self.root / "paseo-home"
        self.paseo_home.mkdir()
        self.paseo_config = self.paseo_home / "config.json"
        self.codex_config = self.root / "config.toml"
        shutil.copyfile(TEMPLATES / "paseo-config.json", self.paseo_config)
        shutil.copyfile(TEMPLATES / "codex-config.toml", self.codex_config)
        self.paseo_config.chmod(0o600)
        self.codex_config.chmod(0o600)
        self.main_selection = self.root / "main-selection.json"
        self.claude_selection = self.root / "claude-selection.json"
        self.main_selection.write_text(
            json.dumps({"models": [{"id": "codex-main"}], "default": "codex-main"}),
            encoding="utf-8",
        )
        self.claude_selection.write_text(
            json.dumps(
                {
                    "models": [{"id": "claude-opus-5-5"}, {"id": "claude-sonnet-5-5"}],
                    "default": "claude-opus-5-5",
                }
            ),
            encoding="utf-8",
        )

    def run_generator(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(GENERATOR),
                "--paseo-config",
                str(self.paseo_config),
                "--codex-config",
                str(self.codex_config),
                "--main-selection",
                str(self.main_selection),
                "--base-url",
                MAIN_URL,
                "--claude-selection",
                str(self.claude_selection),
                "--claude-base-url",
                CLAUDE_URL,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_https_normalization(self) -> None:
        configure_script = KIT / "02-configure.sh"
        normalize = (
            'eval "$(sed -n \'/^normalize_https_url()/,/^}/p\' "$1")"; '
            'normalize_https_url "$2" "$3"'
        )
        command = ["bash", "-c", normalize, "normalize-url", str(configure_script)]
        for value in ("https://sub2.hahaapi.com", "https://sub2.hahaapi.com/v1/"):
            result = subprocess.run(
                [*command, value, "append-v1"], text=True, capture_output=True, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), f"{CLAUDE_URL}/v1")
        for value in ("https://sub2.hahaapi.com", "https://sub2.hahaapi.com/v1/"):
            result = subprocess.run(
                [*command, value, "strip-v1"], text=True, capture_output=True, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), CLAUDE_URL)
        invalid = subprocess.run(
            [*command, "http://sub2.hahaapi.com", "strip-v1"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(invalid.returncode, 0)
        invalid_path = subprocess.run(
            [*command, "https://sub2.hahaapi.com/v1/models", "strip-v1"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(invalid_path.returncode, 0)

    def test_model_ids_are_ordered_unique_and_required(self) -> None:
        self.assertEqual(
            model_selector.parse_model_ids("claude-opus-5-5, claude-sonnet-5-5"),
            ["claude-opus-5-5", "claude-sonnet-5-5"],
        )
        with self.assertRaises(model_selector.ModelSelectionError):
            model_selector.parse_model_ids("claude-opus-5-5 claude-opus-5-5")
        with self.assertRaises(model_selector.ModelSelectionError):
            model_selector.parse_model_ids("   ")

    def test_claude_relay_and_selected_models_are_written(self) -> None:
        result = self.run_generator()
        self.assertEqual(result.returncode, 0, result.stderr)

        config_text = self.paseo_config.read_text(encoding="utf-8")
        config = json.loads(config_text)
        codex = config["agents"]["providers"]["codex"]
        claude = config["agents"]["providers"]["claude"]
        self.assertTrue(codex["enabled"])
        self.assertEqual([item["id"] for item in codex["models"]], ["codex-main"])
        self.assertEqual(
            codex["models"][0]["thinkingOptions"][-1]["id"], "max"
        )
        self.assertTrue(claude["enabled"])
        self.assertEqual(claude["env"], {"ANTHROPIC_BASE_URL": CLAUDE_URL})
        self.assertFalse(claude["env"]["ANTHROPIC_BASE_URL"].endswith("/v1"))
        self.assertEqual(
            [item["id"] for item in claude["models"]],
            ["claude-opus-5-5", "claude-sonnet-5-5"],
        )
        self.assertTrue(claude["models"][0]["isDefault"])
        self.assertFalse(claude["models"][1]["isDefault"])
        self.assertTrue(all("thinkingOptions" not in item for item in claude["models"]))
        self.assertNotIn("codex-bk", config["agents"]["providers"])
        self.assertNotIn(TEST_KEY, config_text + result.stdout + result.stderr)

        codex_config = tomllib.loads(self.codex_config.read_text(encoding="utf-8"))
        self.assertEqual(codex_config["model_provider"], "hahaapi")
        self.assertEqual(codex_config["model"], "codex-main")
        provider = codex_config["model_providers"]["hahaapi"]
        self.assertEqual(provider["base_url"], MAIN_URL)
        self.assertEqual(provider["env_key"], "HAHA_API_KEY")
        filters = codex_config["shell_environment_policy"]["filters"]
        self.assertEqual(filters["ANTHROPIC_API_KEY"], "exclude")
        self.assertNotIn(TEST_KEY, self.codex_config.read_text(encoding="utf-8"))

    def test_provider_environment_reaches_claude_command_without_logging(self) -> None:
        result = self.run_generator()
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(self.paseo_config.read_text(encoding="utf-8"))
        provider_env = config["agents"]["providers"]["claude"]["env"]
        stub = self.root / "claude"
        capture = self.root / "capture"
        stub.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n%s\\n" "$ANTHROPIC_API_KEY" "$ANTHROPIC_BASE_URL" > "$CAPTURE"\n'
            "printf '%s\\n' '2.1.0 (Claude Code)'\n",
            encoding="utf-8",
        )
        stub.chmod(0o755)
        env = {
            "PATH": str(self.root),
            "CAPTURE": str(capture),
            "ANTHROPIC_API_KEY": TEST_KEY,
            **provider_env,
        }
        command_result = subprocess.run(
            [str(stub), "--version"], text=True, capture_output=True, env=env, check=False
        )
        self.assertEqual(command_result.returncode, 0, command_result.stderr)
        self.assertEqual(
            capture.read_text(encoding="utf-8").splitlines(), [TEST_KEY, CLAUDE_URL]
        )
        self.assertNotIn(TEST_KEY, command_result.stdout + command_result.stderr)

    def test_secret_writer_uses_root_only_file_without_echo(self) -> None:
        configure_script = KIT / "02-configure.sh"
        extracted = subprocess.run(
            ["sed", "-n", "/^ensure_secret_file()/,/^}/p", str(configure_script)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(extracted.returncode, 0, extracted.stderr)
        self.assertTrue(extracted.stdout)
        self.assertIn("os.chown(temporary, 0, 0)", extracted.stdout)
        expected_uid, expected_gid = 0, 0
        if os.geteuid() != 0:
            extracted.stdout = extracted.stdout.replace(
                "os.chown(temporary, 0, 0)",
                "os.chown(temporary, os.getuid(), os.getgid())",
            )
            expected_uid, expected_gid = os.getuid(), os.getgid()

        test_key = "test-key-never-echo"
        with tempfile.TemporaryDirectory(prefix="paseo-secret-test-") as temporary:
            secret_path = Path(temporary) / "anthropic.env"
            script = (
                extracted.stdout
                + '\nensure_secret_file "$1" ANTHROPIC_API_KEY "Enter test key: "\n'
            )
            pid, terminal = pty.fork()
            if pid == 0:
                os.execve(
                    "/bin/bash",
                    ["bash", "-c", script, "secret-test", str(secret_path)],
                    {
                        "PATH": f"{Path(sys.executable).parent}:/usr/bin:/bin",
                        "HOME": temporary,
                        "TMPDIR": temporary,
                        "PYTHONDONTWRITEBYTECODE": "1",
                    },
                )

            output = bytearray()
            sent_key = False
            status = None
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                ready, _, _ = select.select([terminal], [], [], 0.1)
                if ready:
                    try:
                        output.extend(os.read(terminal, 4096))
                    except OSError:
                        break
                    if not sent_key and b"Enter test key:" in output:
                        os.write(terminal, test_key.encode("ascii") + b"\n")
                        sent_key = True
                child, child_status = os.waitpid(pid, os.WNOHANG)
                if child:
                    status = child_status
                    break
            if status is None:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                _, status = os.waitpid(pid, 0)
            os.close(terminal)

            self.assertTrue(sent_key, output.decode(errors="replace"))
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode(errors="replace"))
            self.assertEqual(stat.S_IMODE(secret_path.stat().st_mode), 0o600)
            self.assertEqual(secret_path.stat().st_uid, expected_uid)
            self.assertEqual(secret_path.stat().st_gid, expected_gid)
            self.assertIn(test_key, secret_path.read_text(encoding="utf-8"))
            self.assertNotIn(test_key, output.decode(errors="replace"))

    def test_codex_standalone_parses_primary_configuration_when_available(self) -> None:
        codex_bin = shutil.which("codex")
        managed_bin = Path("/srv/paseo/tools/bin/codex")
        if not codex_bin and managed_bin.is_file():
            codex_bin = str(managed_bin)
        if not codex_bin:
            self.skipTest("Codex standalone is not installed in this test environment")
        result = self.run_generator()
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run(
            [codex_bin, "--strict-config", "--help"],
            text=True,
            capture_output=True,
            env={
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "HOME": str(self.root),
                "CODEX_HOME": str(self.root),
                "ANTHROPIC_API_KEY": TEST_KEY,
            },
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(TEST_KEY, result.stdout + result.stderr)

    def test_paseo_cli_parses_generated_config_when_available(self) -> None:
        paseo_bin = shutil.which("paseo")
        installed_bin = Path("/srv/paseo/runtime/apps/node_modules/.bin/paseo")
        if not paseo_bin and installed_bin.is_file():
            paseo_bin = str(installed_bin)
        if not paseo_bin:
            self.skipTest("Paseo CLI is not installed in this test environment")
        result = self.run_generator()
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run(
            [paseo_bin, "daemon", "config", "get", "--home", str(self.paseo_home)],
            text=True,
            capture_output=True,
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.root)},
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(TEST_KEY, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
