# Paseo Package Change Rules

Read this file before changing code, configuration, tests, or release documentation in this package.

## Release Naming

- Name each release directory `paseo-debian-YYYYMMDD<suffix>`.
- On a release, update the directory name, the README title and deployment paths, and the `VALIDATION.md` title and deployment paths.
- The bootstrap `install.sh` must name the current directory so it can locate the package in the downloaded repository archive. Keep this release-specific reference limited to that purpose.
- Do not put a release suffix in runtime state, systemd descriptions, update lock names, temporary paths, or the npm manifest version.
- Use the stable internal package identity `paseo-debian` and the fixed private manifest version `1.0.0`. Do not increment either for a package release.
- Keep exact component versions and the verification date in `VALIDATION.md`; do not pin component versions in the installer or repeat them in the README.

## Deployment Behavior

- Design packages for a fresh Debian 12/13 installation. Do not add migration or compatibility logic for previous package releases unless explicitly requested.
- Resolve current official Node.js LTS, npm, Paseo CLI, Codex standalone, and uv releases when installation or update runs.
- Preserve the multi-step deployment flow, `--force` installation, update rollback, and managed-resource-only uninstall behavior.
- Keep Codex standalone updates behind the successful service-stop check. A failed stop or a service that remains active must not change live runtime paths.
- Do not add a package-owned checksum manifest or checksum comparison. Official installers and package managers retain their own integrity behavior.
- Do not add Docker as a dependency; this package runs Paseo as a native systemd service.

## Editing and Verification

- Inspect the current package and its scripts before editing. Keep changes focused and remove code only when it is demonstrably unreachable or ineffective.
- Test deployment scripts only in isolated directories with command stubs. Never run them against the real `/srv/paseo`, `/etc`, or systemd from a development environment.
- Run syntax checks for changed languages, focused tests for changed behavior, current Paseo configuration parsing, and archive content/mode checks.
- Record only checks actually performed in `VALIDATION.md`; state explicitly when real VPS service startup or Relay pairing was not tested.
- Build a ZIP only from a clean Git commit containing the package. Export that commit as tar, extract with `umask 022`, and create the ZIP from the extracted tree so Unix file modes are preserved; verify ZIP integrity, its single top-level directory, file contents, and stored mode bits. Do not use `git archive --format=zip`, which may omit read permissions for non-executable files.
- Do not initialize Git in a directory with an invalid placeholder `.git`; use an existing valid repository clone when needed. Do not push or publish unless requested.
