#!/usr/bin/env python3
"""Exercise BackAPI configuration generation without a live API or VPS."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path


KIT = Path(__file__).resolve().parents[1]
GENERATOR = KIT / "lib/apply-model-config.py"
TEMPLATES = KIT / "templates"
WRAPPER_TEMPLATE = TEMPLATES / "backapi-codex-wrapper.sh"
BACKUP_URL = "https://sub2.hahaapi.com/v1"
TEST_KEY = "backapi-test-key-never-log"


class BackApiConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="paseo-backapi-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.paseo_home = self.root / "paseo-home"
        self.paseo_home.mkdir()
        self.paseo_config = self.paseo_home / "config.json"
        self.codex_config = self.root / "config.toml"
        self.profile = self.root / "backapi.config.toml"
        shutil.copyfile(TEMPLATES / "paseo-config.json", self.paseo_config)
        shutil.copyfile(TEMPLATES / "codex-config.toml", self.codex_config)
        self.paseo_config.chmod(0o600)
        self.codex_config.chmod(0o600)
        self.main_selection = self.root / "main-selection.json"
        self.back_selection = self.root / "back-selection.json"
        self.main_selection.write_text(
            json.dumps({"models": [{"id": "main-model"}], "default": "main-model"}),
            encoding="utf-8",
        )
        self.back_selection.write_text(
            json.dumps({"models": [{"id": "backup-model"}], "default": "backup-model"}),
            encoding="utf-8",
        )

    def run_generator(self, with_backup: bool) -> subprocess.CompletedProcess[str]:
        args = [
            sys.executable,
            str(GENERATOR),
            "--paseo-config",
            str(self.paseo_config),
            "--codex-config",
            str(self.codex_config),
            "--main-selection",
            str(self.main_selection),
            "--base-url",
            "https://primary.example.test/v1",
            "--wrapper",
            "/srv/paseo/runtime/apps/backapi-codex-wrapper",
            "--backup-codex-profile",
            str(self.profile),
        ]
        if with_backup:
            args.extend(
                [
                    "--back-selection",
                    str(self.back_selection),
                    "--backapi-base-url",
                    BACKUP_URL,
                ]
            )
        return subprocess.run(args, text=True, capture_output=True, check=False)

    def test_backup_url_normalization(self) -> None:
        configure_script = KIT / "02-configure.sh"
        normalize = (
            'eval "$(sed -n \'/^normalize_https_url()/,/^}/p\' "$1")"; '
            'normalize_https_url "$2"'
        )
        base_args = ["bash", "-c", normalize, "normalize-url", str(configure_script)]
        result = subprocess.run(
            [*base_args, "https://sub2.hahaapi.com"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), BACKUP_URL)
        invalid = subprocess.run(
            [*base_args, "http://sub2.hahaapi.com"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(invalid.returncode, 0)

    def test_backup_provider_has_matching_codex_profile(self) -> None:
        result = self.run_generator(with_backup=True)
        self.assertEqual(result.returncode, 0, result.stderr)

        paseo = json.loads(self.paseo_config.read_text(encoding="utf-8"))
        codex = tomllib.loads(self.codex_config.read_text(encoding="utf-8"))
        profile_text = self.profile.read_text(encoding="utf-8")
        profile = tomllib.loads(profile_text)

        self.assertEqual(codex["model_provider"], "hahaapi")
        self.assertEqual(codex["model"], "main-model")
        self.assertEqual(codex["model_providers"]["hahaapi"]["base_url"], "https://primary.example.test/v1")
        provider = paseo["agents"]["providers"]["codex-bk"]
        self.assertEqual(provider["models"][0]["id"], "backup-model")
        self.assertEqual(provider["env"]["OPENAI_API_KEY"], "__paseo_backapi_wrapper__")
        self.assertNotIn("OPENAI_BASE_URL", provider["env"])
        self.assertEqual(profile["model_provider"], "codex-bk")
        self.assertEqual(profile["model"], "backup-model")
        self.assertEqual(profile["model_providers"]["codex-bk"]["base_url"], BACKUP_URL)
        self.assertEqual(profile["model_providers"]["codex-bk"]["env_key"], "OPENAI_API_KEY")
        self.assertEqual(profile["model_providers"]["codex-bk"]["wire_api"], "responses")
        self.assertNotIn(TEST_KEY, profile_text + self.paseo_config.read_text() + self.codex_config.read_text())
        self.assertNotIn(TEST_KEY, result.stdout + result.stderr)

    def test_skipping_backup_removes_profile_and_provider(self) -> None:
        self.profile.write_text("stale = true\n", encoding="utf-8")
        result = self.run_generator(with_backup=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        paseo = json.loads(self.paseo_config.read_text(encoding="utf-8"))
        self.assertNotIn("codex-bk", paseo["agents"]["providers"])
        self.assertFalse(self.profile.exists())

    def test_codex_standalone_parses_generated_profile(self) -> None:
        codex_bin = shutil.which("codex")
        if not codex_bin:
            self.skipTest("Codex standalone is not installed in this test environment")
        result = self.run_generator(with_backup=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.root),
            "CODEX_HOME": str(self.root),
            "OPENAI_API_KEY": TEST_KEY,
        }
        result = subprocess.run(
            [codex_bin, "--profile", "backapi", "--strict-config", "app-server", "--help"],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(TEST_KEY, result.stdout + result.stderr)

    def test_paseo_cli_parses_generated_config(self) -> None:
        paseo_bin = shutil.which("paseo")
        installed_bin = Path("/srv/paseo/runtime/apps/node_modules/.bin/paseo")
        if not paseo_bin and installed_bin.is_file():
            paseo_bin = str(installed_bin)
        if not paseo_bin:
            self.skipTest("Paseo CLI is not installed in this test environment")
        result = self.run_generator(with_backup=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        result = subprocess.run(
            [paseo_bin, "daemon", "config", "get", "--home", str(self.paseo_home)],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(TEST_KEY, result.stdout + result.stderr)

    def test_wrapper_selects_profile_and_forwards_key_without_logging(self) -> None:
        wrapper_text = WRAPPER_TEMPLATE.read_text(encoding="utf-8")
        stub = self.root / "codex-stub"
        key_capture = self.root / "key-capture"
        args_capture = self.root / "args-capture"
        stub.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s' \"$OPENAI_API_KEY\" > \"$CAPTURE_KEY\"\n"
            "printf '%s\\n' \"$@\" > \"$CAPTURE_ARGS\"\n",
            encoding="utf-8",
        )
        stub.chmod(0o755)
        wrapper = self.root / "wrapper"
        wrapper.write_text(
            wrapper_text.replace("/srv/paseo/tools/bin/codex", str(stub)),
            encoding="utf-8",
        )
        wrapper.chmod(0o755)

        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "BACKAPI_API_KEY": TEST_KEY,
            "CAPTURE_KEY": str(key_capture),
            "CAPTURE_ARGS": str(args_capture),
        }
        result = subprocess.run(
            [str(wrapper), "app-server", "--listen", "stdio://"],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(key_capture.read_text(encoding="utf-8"), TEST_KEY)
        self.assertEqual(
            args_capture.read_text(encoding="utf-8").splitlines(),
            ["--profile", "backapi", "app-server", "--listen", "stdio://"],
        )
        self.assertNotIn(TEST_KEY, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
