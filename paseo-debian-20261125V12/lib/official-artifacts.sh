#!/usr/bin/env bash

verify_node_archive() {
  local version="$1" archive="$2" destination="$3"
  local checksums="$destination/SHASUMS256.txt" expected
  curl --connect-timeout 10 --max-time 30 --retry 3 -fsSL \
    "https://nodejs.org/dist/v$version/SHASUMS256.txt" -o "$checksums"
  expected="$(awk -v archive="$archive" '$2 == archive { print $1 }' "$checksums")"
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || {
    echo "Node.js 官方校验清单缺少归档校验值：$archive" >&2
    return 1
  }
  printf '%s  %s\n' "$expected" "$destination/$archive" \
    | sha256sum --check --status - || {
      echo "Node.js 官方归档 SHA-256 校验失败：$archive" >&2
      return 1
    }
}
