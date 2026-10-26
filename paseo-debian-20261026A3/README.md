# paseo-debian-20261026A3

Debian 12 (bookworm) and Debian 13 (trixie) deployment kit for amd64/x86_64 and arm64/aarch64. It installs the current official Node.js LTS, npm latest, Paseo CLI latest, OpenAI Codex standalone latest, and Astral uv latest. Component versions are resolved when the installer runs, not pinned in this package. Versions observed during package verification are recorded in [VALIDATION.md](VALIDATION.md).

## Install

Extract the package and run from its directory in a root SSH session:

```bash
sudo bash ./install.sh
```

The installer runs these steps in order:

```text
00-firewall-relay-check.sh -> 01-install.sh -> 02-configure.sh -> 03-pair.sh
```

It stores the package under `/srv/paseo/deploy-kit/paseo-debian-20261026A3`. The firewall check requires outbound DNS and TCP 443; Paseo Relay does not require inbound ports or firewall rule changes.

## Forced Install

```bash
sudo bash ./install.sh --force
```

`--force` stops Paseo and recreates this package's runtime, systemd unit, configuration, secrets, Paseo state, and Codex standalone state. It preserves `/srv/proj`, `/srv/paseo/worktrees`, other tools in `/srv/paseo/tools`, caches, the `paseo` account, and the saved deployment package. Configuration and pairing must be completed again. This package does not migrate or accept older package state.

Only this package's `/etc/systemd/system/paseo.service.d/10-backapi.conf` is removed; other service drop-ins are preserved.

The Codex installer owns `/srv/paseo/tools/bin/codex` as a symbolic link into `/srv/paseo/.codex/packages/standalone`. Forced install recognizes and removes only a link resolving inside that official standalone tree.

## Component Update

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261026A3/98-update.sh
```

The updater only accepts an installation created by this package. It prepares the latest Node.js, npm, Paseo, and uv releases and downloads the official Codex installer while preserving the current service state. It runs the Codex installer and replaces the runtime only after Paseo has stopped. If stopping fails or the service remains active, it exits without changing the runtime or Codex links. It validates versions and configuration; when the service was running before the update, it also requires local health and a TLS/E2EE Relay status request to pass. A failed post-update check restores the previous runtime and Codex selection.

## Runtime

The service runs as `paseo:paseo`, works in `/srv/proj`, and listens only on `127.0.0.1:6767`. Relay uses TLS/E2EE. The config enables dictation and disables voice mode and the self-hosted Web UI. API keys stay in root-owned `0600` EnvironmentFiles; they are not written into Paseo or Codex configuration files.

Docker is not installed or used. The current Paseo CLI package and this native systemd deployment do not require it.

Useful checks:

```bash
systemctl --no-pager --full status paseo
journalctl -u paseo.service -n 80 --no-pager
ss -lntp 'sport = :6767'
curl --noproxy '*' -fsS http://127.0.0.1:6767/api/health
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261026A3/03-pair.sh
```

The pairing URL is a credential. Use it only in the intended Paseo client and do not paste it into logs or support requests.

## Uninstall

Review the removal set, then execute it:

```bash
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261026A3/99-uninstall.sh --dry-run
sudo bash /srv/paseo/deploy-kit/paseo-debian-20261026A3/99-uninstall.sh --yes
```

Uninstall removes the managed service, runtime, configuration, and Codex standalone state while preserving projects, worktrees, other tools, caches, the `paseo` account, and the saved package source.

## Package Files

- `install.sh`: bootstrap and multi-step setup entry point; forwards `--force`.
- `00-firewall-relay-check.sh`: read-only DNS and outbound HTTPS preflight.
- `01-install.sh`: installs the latest official runtime components.
- `02-configure.sh`: writes current Paseo and Codex configuration and the systemd unit.
- `03-pair.sh`: verifies local health and Relay TLS/E2EE before and after pairing.
- `98-update.sh`: stages current releases and rolls back if post-update checks fail.
- `99-uninstall.sh`: removes only package-managed resources.
- `lib/` and `templates/`: shared checks, configuration writers, and service templates.
- `VALIDATION.md`: records the checks actually run for this package.
- `AGENTS.md`: rules for AI-assisted changes to this package; read it before editing.

## AI Changes

Read [AGENTS.md](AGENTS.md) before changing this package. It defines release naming, stable internal identity, deployment constraints, and verification requirements.

The package has no `SHA256SUMS` file and does not generate or compare its own artifact hashes. Official installers and package managers retain their native installation behavior.
