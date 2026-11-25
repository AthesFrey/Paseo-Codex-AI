#!/usr/bin/env python3
"""Guard the deployment entrypoint order and destructive-operation boundaries."""
from pathlib import Path
import unittest


KIT = Path(__file__).resolve().parents[1]


class DeploymentFlowTests(unittest.TestCase):
    def test_installer_preserves_multistep_order_and_force_argument(self) -> None:
        script = (KIT / "install.sh").read_text(encoding="utf-8")
        steps = [
            'bash "$package_source/00-firewall-relay-check.sh"',
            'bash "$package_source/01-install.sh" "${install_args[@]}"',
            'bash "$KIT_TARGET/02-configure.sh"',
            'bash "$KIT_TARGET/03-pair.sh"',
        ]
        positions = [script.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertIn('[[ "$force" == true ]] && install_args+=(--force)', script)
        self.assertIn('"$(basename "$script_dir")" == "$PACKAGE_DIR_NAME"', script)

    def test_v12_updater_is_release_scoped_and_rolls_back(self) -> None:
        script = (KIT / "98-update.sh").read_text(encoding="utf-8")
        self.assertIn("PACKAGE_RELEASE='paseo-debian-20261125V12'", script)
        self.assertIn('[[ "$(state_value release)" == "$PACKAGE_RELEASE" ]]', script)
        self.assertIn('restore_item "$NODE_ROOT" "$backup/node"', script)
        self.assertIn('restore_codex_state || rollback_status=1', script)
        update_start = script.index("echo 'Node.js、npm、Paseo 和 uv 已准备并校验")
        stop = script.index('systemctl stop paseo.service', update_start)
        codex_install = script.index('/bin/sh "$codex_installer"', stop)
        runtime_switch = script.index('mv -- "$NODE_ROOT" "$backup/node"', codex_install)
        relay_check = script.index('"$PASEO_KIT/lib/relay-check.mjs"', runtime_switch)
        self.assertLess(stop, codex_install)
        self.assertLess(codex_install, runtime_switch)
        self.assertLess(runtime_switch, relay_check)

    def test_uninstall_dry_run_precedes_service_stop_and_deletion(self) -> None:
        script = (KIT / "99-uninstall.sh").read_text(encoding="utf-8")
        dry_run = script.index('if [[ "$mode" == dry-run ]]')
        stop = script.index('if systemctl is-active --quiet paseo.service')
        deletion = script.index('rm -rf -- /etc/paseo /srv/paseo/runtime')
        self.assertLess(dry_run, stop)
        self.assertLess(stop, deletion)


if __name__ == "__main__":
    unittest.main()
