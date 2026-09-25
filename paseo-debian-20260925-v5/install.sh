#!/usr/bin/env bash
# Fetch the Paseo deployment package and run its interactive setup flow.
set -Eeuo pipefail

readonly REPOSITORY='AthesFrey/Paseo-Codex-AI'
readonly RELEASE='paseo-debian-20260925-v5'
readonly KIT_ROOT='/srv/paseo/deploy-kit'
readonly KIT_TARGET="$KIT_ROOT/$RELEASE"
readonly ARCHIVE_URL="https://codeload.github.com/$REPOSITORY/tar.gz/refs/heads/main"

require_root() {
  [[ $EUID == 0 ]] || { echo '请使用：curl .../paseo-debian-20260925-v5/install.sh | sudo bash' >&2; exit 1; }
}

fail() {
  echo "$*" >&2
  exit 1
}

require_root
for command in apt-get chown cmp cp curl find install mkdir mktemp mv rm sha256sum tar uname; do
  command -v "$command" >/dev/null || fail "找不到 $command，无法下载或部署工具包。"
done

[[ -r /etc/os-release ]] || fail '无法读取 /etc/os-release；仅支持 Debian 12/13。'
# shellcheck disable=SC1091
source /etc/os-release
[[ "$ID" == debian && "${VERSION_CODENAME:-}" =~ ^(bookworm|trixie)$ ]] \
  || fail "仅支持 Debian 12 (bookworm) 或 Debian 13 (trixie)。检测到：${PRETTY_NAME:-unknown}"
case "$(uname -m)" in
  x86_64|aarch64) ;;
  *) fail '仅支持 amd64 (x86_64) 或 arm64 (aarch64)。' ;;
esac

[[ ! -L /srv/proj && ! -L /srv/paseo && ! -L "$KIT_ROOT" && ! -L "$KIT_TARGET" ]] \
  || fail '部署路径中不允许符号链接；请检查 /srv/proj 和 /srv/paseo。'
[[ ! -e /srv/proj || -d /srv/proj ]] || fail '/srv/proj 已存在但不是目录。'
[[ -d /srv/proj ]] || install -d -o root -g root -m 0700 /srv/proj
tmp_dir="$(mktemp -d /srv/proj/.paseo-bootstrap.XXXXXX)"
staging_path=''
package_verified=false
kit_available=false
cleanup() {
  local status=$?
  if [[ -n "$staging_path" && -e "$staging_path" ]]; then
    rm -rf -- "$staging_path"
  fi
  if [[ "$status" != 0 && "$package_verified" == true && "$kit_available" != true ]]; then
    echo "部署中断；已校验工具包保留在 $package_source。" >&2
    return "$status"
  fi
  if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
    rm -rf -- "$tmp_dir"
  fi
  return "$status"
}
trap cleanup EXIT

curl --connect-timeout 10 --max-time 180 --retry 3 -fsSL "$ARCHIVE_URL" \
  -o "$tmp_dir/repository.tar.gz"
mkdir "$tmp_dir/extracted"
tar --no-same-owner -xzf "$tmp_dir/repository.tar.gz" -C "$tmp_dir/extracted"

mapfile -t package_paths < <(
  find "$tmp_dir/extracted" -mindepth 2 -maxdepth 4 -type d -name "$RELEASE" -print
)
[[ ${#package_paths[@]} == 1 ]] \
  || fail "GitHub 归档中应恰好包含一个 $RELEASE/ 目录；实际找到 ${#package_paths[@]} 个。"
package_source="${package_paths[0]}"
[[ -f "$package_source/SHA256SUMS" && -f "$package_source/01-install.sh" \
  && -f "$package_source/03-pair.sh" ]] \
  || fail "GitHub 归档缺少 $RELEASE 的关键文件。"
(cd "$package_source" && sha256sum --strict --check SHA256SUMS)
package_verified=true

if [[ -e "$KIT_TARGET" ]]; then
  [[ -d "$KIT_TARGET" && ! -L "$KIT_TARGET" ]] \
    || fail "现有部署包路径不是普通目录：$KIT_TARGET"
  cmp -- "$package_source/SHA256SUMS" "$KIT_TARGET/SHA256SUMS" \
    || fail "已保存工具包与 GitHub main 分支不一致：$KIT_TARGET"
  (cd "$KIT_TARGET" && sha256sum --strict --check SHA256SUMS)
  package_source="$KIT_TARGET"
  kit_available=true
  echo "复用已保存且与 GitHub main 分支一致的 $RELEASE 工具包。"
fi

echo '安装 Relay 检查所需的 nftables 和 CA 证书。'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates nftables

bash "$package_source/00-firewall-relay-check.sh"
bash "$package_source/01-install.sh"

if [[ "$kit_available" != true ]]; then
  install -d -o root -g root -m 0755 "$KIT_ROOT"
  staging_path="$KIT_ROOT/.${RELEASE}.staging.$$"
  [[ ! -e "$staging_path" ]] || fail "暂存路径已存在：$staging_path"
  cp -a -- "$package_source" "$staging_path"
  chown -R root:root "$staging_path"
  (cd "$staging_path" && sha256sum --strict --check SHA256SUMS)
  mv -T -- "$staging_path" "$KIT_TARGET"
  staging_path=''
  kit_available=true
  echo "工具包已保存到 $KIT_TARGET。"
fi

bash "$KIT_TARGET/02-configure.sh"
bash "$KIT_TARGET/03-pair.sh"
