#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Host preparation CHECKS for a fresh Debian or Ubuntu VPS. Read-only: it changes nothing, installs
# nothing and never touches the firewall. It prints what it found and what you have to do.
# Exit code 1 when a blocking problem was found (marked FAIL), 0 otherwise.
# Usage: scripts/bootstrap.sh [--domain NAME]
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

domain=
while [ $# -gt 0 ]; do
  case $1 in
    --domain)
      [ $# -ge 2 ] || die "--domain needs a value"
      domain=$2
      shift
      ;;
    -h | --help)
      sed -n '2,7p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[ -n "$domain" ] || domain=$(env_get RELAY_DOMAIN)
[ -n "$domain" ] || domain=relay.cometcast.de

info "This script only looks. Nothing is installed, changed or restarted."
info "Checking the host for relay name: $domain"
info

# --- operating system ---
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian | ubuntu) ok "OS: ${PRETTY_NAME:-$ID}" ;;
    *) warn "OS ${PRETTY_NAME:-unknown}: written for Debian/Ubuntu, other systems are untested" ;;
  esac
else
  warn "cannot read /etc/os-release"
fi
arch=$(uname -m)
case $arch in
  x86_64 | aarch64) ok "CPU architecture: $arch" ;;
  *) fail "CPU architecture $arch: the image is built for amd64 and arm64 only (UNCERTAIN: arm64 was never run)" ;;
esac
if [ "$arch" = aarch64 ]; then
  warn "arm64: the product's Docker image was only run on amd64 so far"
fi

# --- resources ---
mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)
if [ "$mem_kb" -ge 900000 ]; then
  ok "memory: $((mem_kb / 1024)) MiB"
else
  warn "memory: $((mem_kb / 1024)) MiB; the compose limits assume about 1 GiB"
fi
free_kb=$(df -Pk "$ROOT" | awk 'NR == 2 { print $4 }')
if [ "$free_kb" -ge 2000000 ]; then
  ok "free disk space here: $((free_kb / 1024)) MiB"
else
  fail "free disk space here: $((free_kb / 1024)) MiB (images need about 300 MiB, logs up to 100 MiB; keep 2 GiB free)"
fi

# --- Docker ---
if have_cmd docker; then
  ok "docker: $(docker --version 2>/dev/null)"
  if docker info >/dev/null 2>&1; then
    ok "docker daemon reachable by this user"
  else
    fail "docker daemon not reachable by this user (not running, or not in group 'docker', or use sudo)"
  fi
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose plugin: $(docker compose version --short 2>/dev/null)"
  else
    fail "docker compose plugin missing (see docs/SETUP.md, step 'Install Docker')"
  fi
else
  fail "docker is not installed (see docs/SETUP.md, step 'Install Docker')"
fi
if have_cmd openssl; then ok "openssl present (gen-secrets.sh, verify.sh)"; else fail "openssl missing: apt-get install openssl"; fi
if have_cmd curl; then ok "curl present"; else fail "curl missing: apt-get install curl"; fi
if have_cmd python3; then ok "python3 present (verify.sh WebSocket check)"; else fail "python3 missing: apt-get install python3"; fi

# --- time ---
if have_cmd timedatectl; then
  sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  if [ "$sync" = yes ]; then
    ok "system clock is synchronised"
  else
    warn "system clock not reported as synchronised (needed for TLS and ALTCHA expiry)"
  fi
fi

# --- ports 80 and 443 ---
if have_cmd ss; then
  for port in 80 443; do
    if ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .; then
      owner=$(ss -H -ltnp "sport = :$port" 2>/dev/null | head -n 1 | awk '{ print $NF }')
      if docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -q "cometcast-relay.*:$port->"; then
        ok "port $port: used by this stack already"
      else
        fail "port $port is already in use ($owner); Caddy needs it"
      fi
    else
      ok "port $port is free"
    fi
  done
else
  warn "'ss' not found: ports 80/443 not checked"
fi

# --- UDP port of the STUN service ---
if have_cmd ss; then
  stun_port=$(env_get STUN_PORT)
  [ -n "$stun_port" ] || stun_port=3478
  if ss -H -lun "sport = :$stun_port" 2>/dev/null | grep -q .; then
    if docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -q "cometcast-relay.*:$stun_port->.*/udp"; then
      ok "UDP port $stun_port: used by this stack already"
    else
      fail "UDP port $stun_port is already in use ($(ss -H -lunp "sport = :$stun_port" 2>/dev/null | head -n 1 | awk '{ print $NF }')); the STUN service needs it"
    fi
  else
    ok "UDP port $stun_port is free (STUN service)"
  fi
fi

# --- DNS ---
if have_cmd getent; then
  resolved=$(getent ahosts "$domain" 2>/dev/null | awk '{ print $1 }' | sort -u | tr '\n' ' ' || true)
  if [ -z "${resolved// /}" ]; then
    fail "DNS: $domain does not resolve yet (create the A record, no AAAA record yet: docs/SETUP.md section 2)"
  else
    case $resolved in
      *:*) warn "DNS: $domain has an AAAA record; the ports are published on IPv4 only, so connections over IPv6 fail (docs/SETUP.md section 2: no AAAA record yet)" ;;
    esac
    local_addrs=$(ip -o addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }' | sort -u | tr '\n' ' ' || true)
    match=0
    for a in $resolved; do
      case " $local_addrs " in *" $a "*) match=1 ;; esac
    done
    if [ "$match" -eq 1 ]; then
      ok "DNS: $domain -> $resolved (an address of this host)"
    else
      warn "DNS: $domain -> $resolved, this host has: ${local_addrs:-none found}. Fine behind a provider NAT (some clouds); otherwise the record is wrong and the certificate request will fail"
    fi
  fi
fi

# --- firewall and SSH (read-only) ---
if have_cmd ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ok "ufw is active"
elif have_cmd nft && nft list ruleset 2>/dev/null | grep -q 'chain input'; then
  ok "an nftables input chain exists (check it allows 80 and 443: firewall/nftables.conf)"
else
  warn "no active host firewall found (or not readable without root). Files: firewall/ . Docker-published ports bypass ufw rules, see docs/SETUP.md"
fi
if [ -r /etc/ssh/sshd_config ]; then
  if grep -Eiq '^[[:space:]]*PasswordAuthentication[[:space:]]+no' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
    ok "SSH: PasswordAuthentication no"
  else
    warn "SSH: PasswordAuthentication is not set to 'no' in sshd_config (use keys only; docs/SETUP.md)"
  fi
fi
if have_cmd dpkg && dpkg -s unattended-upgrades >/dev/null 2>&1; then
  ok "unattended-upgrades is installed"
else
  warn "unattended-upgrades not installed (security updates of the host; docs/SETUP.md)"
fi

# --- files of this repository ---
if [ -f "$ROOT/.env" ]; then ok ".env exists"; else warn ".env missing: cp .env.example .env"; fi
if [ -f "$ROOT/secrets/altcha_secret" ]; then
  ok "secrets/altcha_secret exists"
else
  warn "secrets/altcha_secret missing: sudo scripts/gen-secrets.sh"
fi
if git -C "$ROOT" ls-files --error-unmatch .env secrets >/dev/null 2>&1; then
  fail ".env or secrets/ is tracked by git: remove it from the index (git rm --cached) and rotate the secrets"
fi

info
info "Summary: $N_OK ok, $N_WARN warnings, $N_FAIL failures."
info "Next (nothing was done): fix FAILs, then docs/SETUP.md steps: .env, scripts/gen-secrets.sh, scripts/up.sh, scripts/verify.sh."
[ "$N_FAIL" -eq 0 ]
