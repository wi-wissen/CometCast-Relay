#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Host firewall with ufw for the relay: SSH, HTTP (ACME and redirect) and HTTPS in, everything else in denied.
#
# Default: only PRINTS the commands. Run with --apply (as root) to execute them.
# Set SSH_PORT if sshd listens elsewhere. Make sure your SSH session is not locked out: the SSH rule is
# added BEFORE ufw is enabled, but a wrong SSH_PORT still locks you out. Keep a second session open.
#
# Docker note: ports that Docker publishes (80, 443 here) are forwarded before ufw's INPUT rules and
# are NOT filtered by ufw rules. ufw protects the host's own services (SSH and whatever else listens);
# it cannot block a source address for the published ports. Use config/caddy.d/blocklist.caddy for that
# (docs/SETUP.md "Abuse handling"). The 80/443 rules below only matter for traffic that reaches
# a host process (for example docker-proxy for IPv6).
set -euo pipefail

SSH_PORT=${SSH_PORT:-22}
[[ $SSH_PORT =~ ^[0-9]+$ ]] || { echo "error: SSH_PORT must be a number" >&2; exit 1; }

apply=0
case "${1:-}" in
  '') ;;
  --apply) apply=1 ;;
  *) echo "usage: $0 [--apply]" >&2; exit 1 ;;
esac

cmds=(
  "ufw default deny incoming"
  "ufw default allow outgoing"
  "ufw limit ${SSH_PORT}/tcp comment ssh"
  "ufw allow 80/tcp comment http-acme-redirect"
  "ufw allow 443/tcp comment https-wss"
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
