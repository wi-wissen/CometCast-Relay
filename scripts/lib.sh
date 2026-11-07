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

info() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
ok() { N_OK=$((N_OK + 1)); printf '%s[ ok ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { N_WARN=$((N_WARN + 1)); printf '%s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
fail() { N_FAIL=$((N_FAIL + 1)); printf '%s[FAIL]%s %s\n' "$C_FAIL" "$C_OFF" "$*"; }

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

compose() {
  docker compose --project-directory "$ROOT" -f "$ROOT/compose.yaml" "$@"
}

# shellcheck disable=SC2034  # used by update.sh and rollback.sh
IMAGE_REPO=ghcr.io/wi-wissen/cometcast-server

STATE_DIR=$ROOT/.state
HISTORY=$STATE_DIR/version-history

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

# wait_healthy: wait until compose reports every service of the stack as running and healthy.
wait_healthy() {
  compose up -d --wait --wait-timeout "${1:-120}" >/dev/null
}
