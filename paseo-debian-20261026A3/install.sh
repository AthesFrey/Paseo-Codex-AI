#!/usr/bin/env bash
# Fetch the Paseo deployment package and run its interactive setup flow.
set -Eeuo pipefail

readonly REPOSITORY='AthesFrey/Paseo-Codex-AI'
readonly PACKAGE_DIR_NAME='paseo-debian-20261026A3'
readonly KIT_ROOT='/srv/paseo/deploy-kit'
readonly KIT_TARGET="$KIT_ROOT/$PACKAGE_DIR_NAME"
readonly CACHE_ROOT='/srv/paseo/cache'
readonly TASK_CACHE="$CACHE_ROOT/debianvps"
readonly ARCHIVE_URL="https://codeload.github.com/$REPOSITORY/tar.gz/refs/heads/main"

force=false
case "${1:-}" in
  '') ;;
  --force) force=true ;;
  -h|--help)
    cat <<'USAGE'
用法：
  curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261026A3/install.sh | sudo bash
  curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/paseo-debian-20261026A3/install.sh | sudo bash -s -- --force

--force 将参数传递给 01-install.sh，停止并重建本工具管理的运行时、配置、密钥和应用状态。
USAGE
    exit 0
    ;;
  *)
    echo '用法：install.sh [--force]' >&2
    exit 64
    ;;
esac
[[ $# -le 1 ]] || { echo '用法：install.sh [--force]' >&2; exit 64; }

require_root() {
  [[ $EUID == 0 ]] || {
    echo '请使用：curl .../paseo-debian-20261026A3/install.sh | sudo bash' >&2
    exit 1
  }
}

fail() {
  echo "$*" >&2
  exit 1
}

same_package_tree() {
  local source="$1" target="$2"
  diff -qr -- "$source" "$target" >/dev/null \
    && LC_ALL=C diff -q \
      <(cd -- "$source" && find . -printf '%y\t%l\t%P\n' | LC_ALL=C sort) \
      <(cd -- "$target" && find . -printf '%y\t%l\t%P\n' | LC_ALL=C sort) \
      >/dev/null
}

package_modes_valid() {
  local root="$1"
  [[ -z "$(find "$root" ! -type d ! -type f -print -quit)" ]] \
    && [[ -z "$(find "$root" \( ! -uid 0 -o ! -gid 0 \) -print -quit)" ]] \
    && [[ -z "$(find "$root" -type d ! -perm 0755 -print -quit)" ]] \
    && [[ -z "$(find "$root" -type f -name '*.sh' ! -perm 0755 -print -quit)" ]] \
    && [[ -z "$(find "$root" -type f ! -name '*.sh' ! -perm 0644 -print -quit)" ]]
}

require_root
for command in apt-get chown cp curl diff find install mkdir mktemp mv rm stat tar uname; do
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
[[ -d /srv/proj ]] || install -d -o root -g root -m 0755 /srv/proj
for directory in /srv/paseo "$CACHE_ROOT"; do
  if [[ -e "$directory" || -L "$directory" ]]; then
    [[ -d "$directory" && ! -L "$directory" ]] || fail "部署目录不是普通目录：$directory"
  else
    install -d -o root -g root -m 0755 "$directory"
  fi
done

install -d -o root -g root -m 0700 "$TASK_CACHE"
bootstrap_tmp="$(mktemp -d "$TASK_CACHE/paseo-debian-bootstrap.XXXXXX")"
staging_path=''
package_source=''
kit_available=false
script_source="${BASH_SOURCE[0]-}"
if [[ -n "$script_source" && -f "$script_source" ]]; then
  script_dir="$(cd -- "$(dirname -- "$script_source")" && pwd)"
else
  script_dir=''
fi
cleanup() {
  local status=$?
  if [[ -n "$staging_path" && -e "$staging_path" ]]; then
    rm -rf -- "$staging_path"
  fi
  if [[ -n "$bootstrap_tmp" && -d "$bootstrap_tmp" ]]; then
    rm -rf -- "$bootstrap_tmp"
  fi
  return "$status"
}
trap cleanup EXIT

if [[ "$(basename "$script_dir")" == "$PACKAGE_DIR_NAME" \
  && -f "$script_dir/01-install.sh" \
  && -f "$script_dir/03-pair.sh" ]]; then
  package_source="$script_dir"
  echo "使用当前目录中的 $PACKAGE_DIR_NAME 工具包。"
else
  curl --connect-timeout 10 --max-time 180 --retry 3 -fsSL "$ARCHIVE_URL" \
    -o "$bootstrap_tmp/repository.tar.gz"
  mkdir "$bootstrap_tmp/extracted"
  tar --no-same-owner -xzf "$bootstrap_tmp/repository.tar.gz" -C "$bootstrap_tmp/extracted"

  mapfile -t package_paths < <(
    find "$bootstrap_tmp/extracted" -mindepth 2 -maxdepth 4 -type d -name "$PACKAGE_DIR_NAME" -print
  )
  [[ ${#package_paths[@]} == 1 ]] \
    || fail "GitHub 归档中应恰好包含一个 $PACKAGE_DIR_NAME/ 目录；实际找到 ${#package_paths[@]} 个。"
  package_source="${package_paths[0]}"
fi
[[ -f "$package_source/01-install.sh" \
  && -f "$package_source/03-pair.sh" ]] \
  || fail "$PACKAGE_DIR_NAME 工具包缺少关键文件。"

if [[ -e "$KIT_TARGET" ]]; then
  [[ -d "$KIT_TARGET" && ! -L "$KIT_TARGET" ]] \
    || fail "现有部署包路径不是普通目录：$KIT_TARGET"
  [[ "$(stat -c '%u:%g:%a' -- "$KIT_ROOT")" == '0:0:755' ]] \
    || fail "已保存部署包父目录必须为 root:root、0755：$KIT_ROOT"
  same_package_tree "$package_source" "$KIT_TARGET" \
    || fail "已保存工具包与当前来源内容不一致：$KIT_TARGET"
  package_modes_valid "$KIT_TARGET" \
    || fail "已保存工具包权限不符合要求（目录 0755、普通文件 0644、shell 入口 0755）：$KIT_TARGET"
  package_source="$KIT_TARGET"
  kit_available=true
  echo "复用已保存且与当前来源一致的 $PACKAGE_DIR_NAME 工具包。"
fi

echo '安装 Relay 检查所需的 nftables 和 CA 证书。'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates nftables

bash "$package_source/00-firewall-relay-check.sh"
install_args=()
[[ "$force" == true ]] && install_args+=(--force)
bash "$package_source/01-install.sh" "${install_args[@]}"

if [[ "$kit_available" != true ]]; then
  install -d -o root -g root -m 0755 "$KIT_ROOT"
  staging_path="$TASK_CACHE/.${RELEASE}.staging.$$"
  [[ ! -e "$staging_path" ]] || fail "暂存路径已存在：$staging_path"
  cp -a -- "$package_source" "$staging_path"
  [[ -z "$(find "$staging_path" ! -type d ! -type f -print -quit)" ]] \
    || fail '工具包只允许包含普通文件和目录。'
  find "$staging_path" -type d -exec chmod 0755 {} +
  find "$staging_path" -type f -name '*.sh' -exec chmod 0755 {} +
  find "$staging_path" -type f ! -name '*.sh' -exec chmod 0644 {} +
  chown -R root:root "$staging_path"
  mv -T -- "$staging_path" "$KIT_TARGET"
  staging_path=''
  kit_available=true
  echo "工具包已保存到 $KIT_TARGET。"
fi

bash "$KIT_TARGET/02-configure.sh"
bash "$KIT_TARGET/03-pair.sh"
