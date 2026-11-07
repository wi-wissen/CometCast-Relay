#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unit tests of the helpers in lib.sh that decide things: version comparison (the minimum server version check of
# update.sh/rollback.sh/up.sh), the image digest lock file and the SSH port list. No Docker, no network. Used by CI.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fails=0
t() { # t DESCRIPTION COMMAND...: the command must succeed
  local d=$1
  shift
  if "$@" >/dev/null 2>&1; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=$((fails + 1)); fi
}
n() { # n DESCRIPTION COMMAND...: the command must fail
  local d=$1
  shift
  if "$@" >/dev/null 2>&1; then printf 'FAIL %s\n' "$d"; fails=$((fails + 1)); else printf 'ok   %s\n' "$d"; fi
}

t "0.1.0 < 0.1.1" version_lt 0.1.0 0.1.1
t "0.9.0 < 0.10.0 (numeric, not text)" version_lt 0.9.0 0.10.0
t "0.1.9 < 0.2.0" version_lt 0.1.9 0.2.0
t "1.0.0-rc1 < 1.0.0 (pre-release is older)" version_lt 1.0.0-rc1 1.0.0
t "1.0.0-rc1 < 1.0.0-rc2" version_lt 1.0.0-rc1 1.0.0-rc2
t "1.0.0-rc2 < 1.0.0-rc10" version_lt 1.0.0-rc2 1.0.0-rc10
t "0.9.9 < 1.0.0-rc1" version_lt 0.9.9 1.0.0-rc1
n "0.1.1 not < 0.1.0" version_lt 0.1.1 0.1.0
n "equal versions are not <" version_lt 0.1.0 0.1.0
n "1.0.0 not < 1.0.0-rc1" version_lt 1.0.0 1.0.0-rc1
n "0.10.0 not < 0.9.0" version_lt 0.10.0 0.9.0

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# min_server_version: file, comments, override.
test_min() (
  ROOT=$tmp
  printf '# comment\n\n0.3.0   # trailing\n' >"$tmp/MIN_SERVER_VERSION"
  [ "$(MIN_SERVER_VERSION='' min_server_version)" = 0.3.0 ] || exit 1
  [ "$(MIN_SERVER_VERSION=0.5.0 min_server_version)" = 0.5.0 ] || exit 1
  # require_min_version dies (exit 1 in a subshell) below the minimum and passes at or above it.
  (MIN_SERVER_VERSION='' require_min_version 0.3.0 version) || exit 1
  (MIN_SERVER_VERSION='' require_min_version 0.4.2 version) || exit 1
  if (MIN_SERVER_VERSION='' require_min_version 0.2.9 "rollback target") 2>"$tmp/err"; then exit 1; fi
  grep -q 'older than the minimum server version 0.3.0' "$tmp/err" || exit 1
  : >"$tmp/MIN_SERVER_VERSION"
  (MIN_SERVER_VERSION='' require_min_version 0.0.1 version) || exit 1
)
t "minimum server version: file, override, refusal message" test_min

# image lock file
test_lock() (
  STATE_DIR=$tmp/state
  IMAGE_LOCK=$STATE_DIR/image-lock
  d1=sha256:$(printf 'a%.0s' $(seq 64))
  d2=sha256:$(printf 'b%.0s' $(seq 64))
  [ -z "$(lock_digest 0.1.0)" ] || exit 1
  lock_record 0.1.0 "$d1"
  lock_record 0.1.1 "$d2"
  [ "$(lock_digest 0.1.0)" = "$d1" ] || exit 1
  lock_record 0.1.0 "$d2"
  [ "$(lock_digest 0.1.0)" = "$d2" ] || exit 1
  [ "$(grep -c '^0.1.0 ' "$IMAGE_LOCK")" = 1 ] || exit 1
  lock_record 0.1.0 ""
  [ -z "$(lock_digest 0.1.0)" ] || exit 1
  [ "$(lock_digest 0.1.1)" = "$d2" ] || exit 1
)
t "image lock: record, replace, remove" test_lock

# SSH port detection: the session's own port is always included (a wrong list locks you out).
got=$(SSH_CONNECTION='198.51.100.7 51234 203.0.113.9 2222' detect_ssh_ports)
case ",$got," in *,2222,*) printf 'ok   %s\n' "ssh ports include the port of the current session ($got)" ;; *)
  printf 'FAIL %s\n' "ssh ports: $got"
  fails=$((fails + 1))
  ;;
esac

[ "$fails" -eq 0 ] || die "$fails test(s) failed"
info "all lib tests passed"
