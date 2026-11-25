#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


KIT = Path(__file__).resolve().parents[1]


def main():
    install = (KIT / "01-install.sh").read_text(encoding="utf-8")
    update = (KIT / "98-update.sh").read_text(encoding="utf-8")
    uninstall = (KIT / "99-uninstall.sh").read_text(encoding="utf-8")

    assert 'readlink -- "$path")" == "$PASEO_CLAUDE_LOCAL_BIN"' in install
    assert 'readlink -- "$PASEO_CLAUDE_BIN")" == "$PASEO_CLAUDE_LOCAL_BIN"' in install
    assert 'readlink -- "$CLAUDE_BIN")" == "$CLAUDE_LOCAL_BIN"' in update
    assert 'readlink -- "$CLAUDE_BIN")" == "$CLAUDE_LOCAL_BIN"' in uninstall

    readlink = shutil.which("readlink")
    assert readlink is not None, "readlink is required"

    with tempfile.TemporaryDirectory(prefix="paseo-claude-link-") as temporary:
        root = Path(temporary)
        versions = root / ".local/share/claude/versions/2.1.316"
        local_bin_dir = root / ".local/bin"
        managed_bin_dir = root / "tools/bin"
        versions.mkdir(parents=True)
        local_bin_dir.mkdir(parents=True)
        managed_bin_dir.mkdir(parents=True)

        versioned_command = versions / "claude"
        versioned_command.write_text(
            "#!/bin/sh\nprintf '%s\\n' 'Claude Code 2.1.316'\n", encoding="utf-8"
        )
        versioned_command.chmod(0o755)
        local_command = local_bin_dir / "claude"
        managed_command = managed_bin_dir / "claude"
        local_command.symlink_to(versioned_command)
        managed_command.symlink_to(local_command)

        direct_target = subprocess.check_output(
            [readlink, "--", os.fspath(managed_command)], text=True
        ).rstrip("\n")
        canonical_target = subprocess.check_output(
            [readlink, "-m", os.fspath(managed_command)], text=True
        ).rstrip("\n")
        assert direct_target == os.fspath(local_command)
        assert canonical_target == os.fspath(versioned_command)
        assert canonical_target != direct_target

        output = subprocess.check_output(
            [os.fspath(managed_command), "--version"], text=True
        )
        assert output == "Claude Code 2.1.316\n"


if __name__ == "__main__":
    main()
