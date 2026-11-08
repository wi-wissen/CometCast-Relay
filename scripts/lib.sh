#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared helpers for the scripts in this folder. Source it, do not run it.
# shellcheck shell=bash

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_FAIL=''; C_OFF=''
fi

N_OK=0
N_WARN=0
N_FAIL=0
# Failures are counted per class so that verify.sh can tell "the relay is broken" (core) from "the STUN
# service is broken" (stun): set CLASS before a group of checks.
CLASS=core
N_FAIL_STUN=0

info() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
ok() { N_OK=$((N_OK + 1)); printf '%s[ ok ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { N_WARN=$((N_WARN + 1)); printf '%s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
fail() {
  N_FAIL=$((N_FAIL + 1))
  [ "$CLASS" != stun ] || N_FAIL_STUN=$((N_FAIL_STUN + 1))
  printf '%s[FAIL]%s %s\n' "$C_FAIL" "$C_OFF" "$*"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# env_get KEY [FILE]: value of the last "KEY=VALUE" line (quotes removed). The file is read as
# text, never run as shell code. Prints nothing when the key is missing.
env_get() {
  local file=${2:-$ROOT/.env}
  [ -f "$file" ] || return 0
  awk -F= -v key="$1" '
    $0 ~ /^[ \t]*#/ { next }
    {
      k = $1; gsub(/^[ \t]+|[ \t]+$/, "", k)
      if (k == key) {
        v = substr($0, index($0, "=") + 1)
        gsub(/^[ \t]+|[ \t\r]+$/, "", v)
        if (v ~ /^".*"$/ || v ~ /^'\''.*'\''$/) v = substr(v, 2, length(v) - 2)
        val = v; found = 1
      }
    }
    END { if (found) print val }' "$file"
}

# env_set KEY VALUE [FILE]: replace the KEY line (or append it). Writes a temporary file next to
# the target and renames it, keeping the target's mode.
env_set() {
  local key=$1 value=$2 file=${3:-$ROOT/.env} tmp
  [ -f "$file" ] || die "missing $file"
  tmp=$(mktemp "$file.XXXXXX")
  chmod --reference="$file" "$tmp"
  awk -F= -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    {
      k = $1; gsub(/^[ \t]+|[ \t]+$/, "", k)
      if ($0 !~ /^[ \t]*#/ && k == key) { if (!done) print key "=" value; done = 1; next }
      print
    }
    END { if (!done) print key "=" value }' "$file" >"$tmp"
  mv "$tmp" "$file"
}

# Exact release version: MAJOR.MINOR.PATCH with an optional -prerelease, no "v", no +build.
is_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; }

# version_lt A B: succeeds when version A is older than B (semantic versioning: 1.0.0-rc1 < 1.0.0;
# two pre-releases compare as text with version sort). Both must pass is_version.
version_lt() {
  local a=$1 b=$2 ac bc ap bp
  [ "$a" != "$b" ] || return 1
  ac=${a%%-*}; bc=${b%%-*}
  ap=; bp=
  [ "$ac" = "$a" ] || ap=${a#*-}
  [ "$bc" = "$b" ] || bp=${b#*-}
  if [ "$ac" != "$bc" ]; then
    [ "$(printf '%s\n%s\n' "$ac" "$bc" | sort -V | head -n 1)" = "$ac" ]
    return
  fi
  # Same MAJOR.MINOR.PATCH: a pre-release is older than the release.
  if [ -n "$ap" ] && [ -z "$bp" ]; then return 0; fi
  if [ -z "$ap" ] && [ -n "$bp" ]; then return 1; fi
  [ "$(printf '%s\n%s\n' "$ap" "$bp" | sort -V | head -n 1)" = "$ap" ]
}

# The oldest server release that understands every setting of config/relay.toml (the [stun] section).
# Source of truth: the file MIN_SERVER_VERSION in the repository root; the environment variable
# MIN_SERVER_VERSION overrides it (for a relay.toml without [stun], or a fork). Empty = no check.
min_server_version() {
  local v=${MIN_SERVER_VERSION:-}
  if [ -z "$v" ] && [ -f "$ROOT/MIN_SERVER_VERSION" ]; then
    v=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$ROOT/MIN_SERVER_VERSION" | head -n 1 | tr -d '[:space:]')
  fi
  printf '%s' "$v"
}

# require_min_version VERSION WHAT: die with a clear message when VERSION is older than the minimum.
require_min_version() {
  local min
  min=$(min_server_version)
  [ -n "$min" ] || return 0
  is_version "$min" || die "MIN_SERVER_VERSION '$min' is not an exact version"
  if version_lt "$1" "$min"; then
    die "$2 $1 is older than the minimum server version $min: config/relay.toml has a [stun] section, which servers older than $min refuse to start with ('unknown field stun'). Use $min or newer, or remove [stun] from config/relay.toml and the MIN_SERVER_VERSION file (see docs/SETUP.md 10.4)."
  fi
}

compose() {
  docker compose --project-directory "$ROOT" -f "$ROOT/compose.yaml" "$@"
}

# valid_port VALUE: succeeds for a port number 1..65535 (decimal, no leading zero).
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]; }

# check_ip: the address that update.sh and rollback.sh connect to for their checks (verify.sh --ip): BIND_ADDR
# from .env when it names one address (the published ports listen only there), else 127.0.0.1.
check_ip() {
  local a
  a=$(env_get BIND_ADDR)
  case $a in
    '' | 0.0.0.0 | :: | '[::]') printf '127.0.0.1' ;;
    *) printf '%s' "$a" ;;
  esac
}

# shellcheck disable=SC2034  # used by update.sh and rollback.sh
IMAGE_REPO=ghcr.io/wi-wissen/cometcast-server

STATE_DIR=$ROOT/.state
HISTORY=$STATE_DIR/version-history

# state_lock: take an exclusive lock (.state/lock) for the rest of this process, so that up.sh, update.sh and
# rollback.sh never run at the same time. Dies at once when another one holds it. A script started by the
# holder (update.sh runs rollback.sh) inherits the lock: COMETCAST_LOCK_PID names the holder's PID.
state_lock() {
  if [ -n "${COMETCAST_LOCK_PID:-}" ] && [ "$COMETCAST_LOCK_PID" = "$PPID" ]; then return 0; fi
  need_cmd flock
  mkdir -p "$STATE_DIR"
  exec 9>>"$STATE_DIR/lock"
  flock -n 9 || die "another up.sh, update.sh or rollback.sh is running (lock: $STATE_DIR/lock); wait until it has finished"
  COMETCAST_LOCK_PID=$$
  export COMETCAST_LOCK_PID
}

# record_version VERSION: append "UTC-time version" to the history used by rollback.sh.
record_version() {
  mkdir -p "$STATE_DIR"
  # Do not repeat the same version twice in a row.
  if [ -f "$HISTORY" ] && [ "$(awk 'END { print $2 }' "$HISTORY")" = "$1" ]; then return 0; fi
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$HISTORY"
}

# previous_version CURRENT: the most recent recorded version that differs from CURRENT.
previous_version() {
  [ -f "$HISTORY" ] || return 0
  awk -v cur="$1" '$2 != cur { v = $2 } END { if (v != "") print v }' "$HISTORY"
}

# wait_healthy [SECONDS] [SERVICE...]: wait until compose reports the services (default: all) as running
# and healthy. update.sh waits for the core services only (cometcast-server, caddy), so that a
# broken STUN service alone does not count as a failed update.
wait_healthy() {
  local secs=${1:-120}
  shift || true
  compose up -d --wait --wait-timeout "$secs" "$@" >/dev/null
}

# --- image digests (a lock file next to the version history) ---
# .state/image-lock: "VERSION sha256:..." per line. update.sh and up.sh record the digest of the image
# they run; compose.yaml then starts exactly that digest (COMETCAST_IMAGE_DIGEST in .env), so a tag that
# is moved in the registry later does not change what runs here.
IMAGE_LOCK=$STATE_DIR/image-lock

# lock_digest VERSION: the recorded digest ("sha256:...") or nothing.
lock_digest() {
  [ -f "$IMAGE_LOCK" ] || return 0
  awk -v v="$1" '$1 == v { d = $2 } END { if (d != "") print d }' "$IMAGE_LOCK"
}

# lock_record VERSION DIGEST: remember the digest (replaces an earlier entry of that version; an empty
# DIGEST only removes the entry: a locally built image has none).
lock_record() {
  mkdir -p "$STATE_DIR"
  local tmp
  tmp=$(mktemp "$STATE_DIR/image-lock.XXXXXX")
  {
    [ ! -f "$IMAGE_LOCK" ] || awk -v v="$1" '$1 != v' "$IMAGE_LOCK"
    [ -z "${2:-}" ] || printf '%s %s\n' "$1" "$2"
  } >"$tmp"
  mv "$tmp" "$IMAGE_LOCK"
}

# image_digest IMAGE: the registry digest of a local image ("sha256:...") or nothing (locally built).
image_digest() {
  docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$1" 2>/dev/null | sed -n 's/^.*@\(sha256:[0-9a-f]\{64\}\)$/\1/p'
}

# pin_version VERSION: write COMETCAST_VERSION and the matching COMETCAST_IMAGE_DIGEST (empty when none
# is known) to .env.
pin_version() {
  env_set COMETCAST_VERSION "$1"
  env_set COMETCAST_IMAGE_DIGEST "$(lock_digest "$1")"
}

# --- SSH port detection (firewall scripts) ---
# detect_ssh_ports: the TCP ports sshd listens on, comma separated, from (1) the session you are in
# (SSH_CONNECTION), (2) `sshd -T` (root only), (3) the listening sockets of sshd, (4) sshd_config, else 22.
detect_ssh_ports() {
  local ports=() p line
  if [ -n "${SSH_CONNECTION:-}" ]; then
    p=$(awk '{ print $4 }' <<<"$SSH_CONNECTION")
    [[ $p =~ ^[0-9]+$ ]] && ports+=("$p")
  fi
  if have_cmd sshd; then
    while read -r p; do [[ $p =~ ^[0-9]+$ ]] && ports+=("$p"); done < <(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }')
  fi
  if [ "${#ports[@]}" -eq 0 ] && have_cmd ss; then
    while read -r line; do
      p=${line##*:}
      [[ $p =~ ^[0-9]+$ ]] && ports+=("$p")
    done < <(ss -H -ltnp 2>/dev/null | awk '/"sshd"/ { print $4 }')
  fi
  if [ "${#ports[@]}" -eq 0 ]; then
    while read -r p; do [[ $p =~ ^[0-9]+$ ]] && ports+=("$p"); done < <(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk 'tolower($1) == "port" { print $2 }')
  fi
  [ "${#ports[@]}" -gt 0 ] || ports=(22)
  printf '%s\n' "${ports[@]}" | sort -un | paste -sd, -
}
