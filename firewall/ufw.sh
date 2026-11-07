#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Host firewall with ufw for the relay: SSH, HTTP (ACME and redirect) and HTTPS in, everything else in denied.
#
# Default: only PRINTS the commands. Run with --apply (as root) to execute them.
# The SSH port(s) are detected (the port of your current SSH session, `sshd -T` as root, the listening sshd
# sockets, sshd_config, else 22) and printed; set SSH_PORT (one port or a comma separated list) to override. A wrong
# port locks you out: read the printed commands, and keep a second session open.
# SSH is allowed without ufw's `limit` rule (6 new connections per 30 s and address), which throttles scripted logins
# (ansible, one session per command). Key-only SSH is the protection against guessing (docs/SETUP.md section 3, step 2); set
# SSH_LIMIT=1 to use `ufw limit` anyway. ufw's own rules already allow DHCP/DHCPv6 and ICMP.
#
# Docker note: ports that Docker publishes (80, 443, 3478/udp here) are forwarded before ufw's INPUT rules and
# are NOT filtered by ufw rules. ufw protects the host's own services (SSH and whatever else listens);
# it cannot block a source address for the published ports. Use config/caddy.d/blocklist.caddy for that
# (docs/SETUP.md "Abuse handling"). The 80/443/3478 rules below only matter for traffic that reaches
# a host process (for example docker-proxy for IPv6).
# STUN rate limiting: ufw has no rule for it that works on Docker-published ports. firewall/stun-ratelimit.nft.in
# has the per-source limit (own nft table, prerouting, before Docker's NAT); generate and load it in addition to ufw:
#   firewall/gen-nftables.sh && sudo nft -f firewall/generated/stun-ratelimit.nft   (docs/SETUP.md "STUN service")
# Set STUN_PORT if the STUN service is published on another UDP port.
set -euo pipefail

# shellcheck source=../scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

ssh_source=given
if [ -z "${SSH_PORT:-}" ]; then
  SSH_PORT=$(detect_ssh_ports)
  ssh_source=detected
fi
IFS=, read -r -a ssh_ports <<<"$SSH_PORT"
for p in "${ssh_ports[@]}"; do
  [[ $p =~ ^[0-9]+$ ]] || { echo "error: SSH_PORT must be a number or a comma separated list of numbers" >&2; exit 1; }
done
echo "# SSH ports: $SSH_PORT ($ssh_source)" >&2
SSH_LIMIT=${SSH_LIMIT:-0}
STUN_PORT=${STUN_PORT:-$(env_get STUN_PORT)}
STUN_PORT=${STUN_PORT:-3478}
[[ $STUN_PORT =~ ^[0-9]+$ ]] || { echo "error: STUN_PORT must be a number" >&2; exit 1; }

apply=0
case "${1:-}" in
  '') ;;
  --apply) apply=1 ;;
  *) echo "usage: $0 [--apply]" >&2; exit 1 ;;
esac

ssh_verb=allow
[ "$SSH_LIMIT" != 1 ] || ssh_verb=limit
cmds=(
  "ufw default deny incoming"
  "ufw default allow outgoing"
)
for p in "${ssh_ports[@]}"; do
  cmds+=("ufw $ssh_verb ${p}/tcp comment ssh")
done
cmds+=(
  "ufw allow 80/tcp comment http-acme-redirect"
  "ufw allow 443/tcp comment https-wss"
  "ufw allow ${STUN_PORT}/udp comment stun"
  "ufw --force enable"
)

if [ "$apply" -eq 0 ]; then
  echo "# Dry run. These commands would be executed with --apply (as root):"
  printf '%s\n' "${cmds[@]}"
  exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "error: --apply needs root" >&2; exit 1; }
command -v ufw >/dev/null 2>&1 || { echo "error: ufw is not installed (apt-get install ufw)" >&2; exit 1; }
if ! grep -Eq '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
  echo "warning: IPV6 is not 'yes' in /etc/default/ufw; IPv6 traffic is not filtered" >&2
fi
for c in "${cmds[@]}"; do
  echo "+ $c"
  # shellcheck disable=SC2086  # the commands are plain words by construction
  $c
done
ufw status verbose
