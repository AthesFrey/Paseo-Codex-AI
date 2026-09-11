#!/usr/bin/env bash
# Relay uses outbound HTTPS only. This script is intentionally read-only:
# it never adds/removes rules, edits the user's port lists, or reloads nftables.
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo '请以 root 或 sudo bash 执行。' >&2; exit 1; }
command -v nft >/dev/null || { echo '找不到 nft；先安装 nftables。' >&2; exit 1; }
command -v getent >/dev/null || { echo '找不到 getent；先安装 libc 运行时工具。' >&2; exit 1; }
command -v curl >/dev/null || { echo '找不到 curl；先安装 curl。' >&2; exit 1; }

echo '检查：Relay 不要求任何入站端口。'
output_chain_file="$(mktemp /tmp/paseo-v3.2-output-chain.XXXXXX)"
trap 'rm -f "$output_chain_file"' EXIT
if nft list chain inet filter output >"$output_chain_file" 2>/dev/null; then
  if grep -Eq 'policy accept|ct state established,related accept|ct state related,established accept' "$output_chain_file"; then
    echo 'OK：当前 nftables output 链存在允许出站/回包的规则。'
  else
    echo 'WARN：output 链不是明显的 accept；请在独立的出站防火墙配置中允许 DNS 和 TCP 443。未修改规则。' >&2
  fi
else
  echo 'INFO：没有检测到 inet filter output；本脚本不创建它。请确认主机默认出站策略允许 DNS/TCP 443。'
fi

getent ahosts relay.paseo.sh | sed -n '1,4p'
relay_code="$(curl --noproxy '*' --connect-timeout 5 --max-time 10 \
  -sS -o /dev/null -w '%{http_code}' https://relay.paseo.sh/ || true)"
case "$relay_code" in
  2*|3*|4*) echo "OK：relay.paseo.sh:443 可通过 HTTPS 建立连接（HTTP $relay_code）。" ;;
  *) echo "无法访问 relay.paseo.sh:443（HTTP ${relay_code:-network-error}）。请检查独立出站规则、DNS 和系统时间。" >&2; exit 1 ;;
esac

echo 'FIREWALL_RELAY_CHECK_OK：未添加任何入站端口或 nftables 规则。'
