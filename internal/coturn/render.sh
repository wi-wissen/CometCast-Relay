#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fills deploy/coturn/turnserver.conf.template with values from deploy/.env and
# deploy/secrets/turn_secret and writes deploy/coturn/turnserver.conf (not committed).
# Run from anywhere:  deploy/coturn/render.sh
#
# Safety rules:
#  - .env is NOT run as shell code. It is read line by line as KEY=VALUE.
#  - Every value is checked and the script stops with an error otherwise: realm from a short
#    list of characters, addresses as real IPv4/IPv6 addresses (not unspecified, loopback or
#    multicast), ports as numbers 1-65535 with min <= max, the secret as ONE line of safe
#    characters (a file with several lines is refused, never merged).
#  - The values are inserted as plain text (awk, no pattern matching), so characters such
#    as & | \ have no special meaning anyway.
#  - The output file is written with mode 600 (also when an older file with other
#    permissions exists), via a temporary file that replaces it in one step.
#  - Group access for coturn: TURN_CONF_GROUP=<gid> gives the file (and certs/privkey.pem, if it
#    exists) to that group with mode 640. It must be the group the coturn container runs with
#    (COTURN_GID in .env, default 3478, see docker-compose.yml). 65534 (nogroup/nobody) is refused:
#    on Debian/Ubuntu hosts it is shared by other daemons, which could then read the TURN secret
#    and the TLS key.
#
# Tested with dry renders (deploy/coturn/test-render.sh) and, in the first real run, rendered output
# was read by coturn 4.18.0 in Docker (docs/server.md).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
deploy=$(dirname "$here")

die() {
  echo "error: $*" >&2
  exit 1
}

[ -f "$deploy/.env" ] || die "missing $deploy/.env (copy .env.example)"
[ -f "$deploy/secrets/turn_secret" ] || die "missing $deploy/secrets/turn_secret"

nl='
'

# Read one setting from .env: the last line "KEY=VALUE" wins; quotes around VALUE are removed.
env_value() {
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
    END { if (found) print val }' "$deploy/.env"
}

# Stop unless "$2" (the value of setting "$1") is one line that matches the grep pattern "$3"
# completely.
check() {
  case $2 in
    *"$nl"*) die "$1 has more than one line" ;;
  esac
  if ! printf '%s\n' "$2" | grep -Eq "^($3)\$"; then
    die "$1 has an empty value or characters that are not allowed here"
  fi
}

# Stop unless "$2" is a plausible address for setting "$1": a dotted-quad IPv4 address or an
# IPv6 address in hex notation, and not unspecified, loopback or multicast (such a value
# can only be a mistake in a relay setting).
check_ip() {
  case $2 in
    *"$nl"*) die "$1 has more than one line" ;;
  esac
  if ! printf '%s\n' "$2" | awk '
    function v4(s,    n, a, i) {
      n = split(s, a, ".")
      if (n != 4) return 0
      for (i = 1; i <= 4; i++) {
        if (a[i] !~ /^(0|[1-9][0-9]*)$/ || length(a[i]) > 3 || a[i] + 0 > 255) return 0
      }
      if (a[1] + 0 == 0 || a[1] + 0 == 127 || a[1] + 0 >= 224) return 0
      return 1
    }
    function v6(s,    n, a, i, cnt, tmp, dbl, first) {
      if (s !~ /^[0-9A-Fa-f:]+$/) return 0
      if (s ~ /:::/) return 0
      tmp = s
      dbl = gsub(/::/, "@", tmp)
      if (dbl > 1) return 0
      if (s ~ /^:[^:]/ || s ~ /[^:]:$/) return 0
      n = split(s, a, ":")
      cnt = 0
      for (i = 1; i <= n; i++) {
        if (a[i] != "") {
          if (length(a[i]) > 4) return 0
          cnt++
        }
      }
      if (dbl == 1) { if (cnt > 7) return 0 } else if (cnt != 8) return 0
      # not :: (unspecified), not ::1 (loopback), not ff00::/8 (multicast)
      if (s == "::" || s == "::1") return 0
      first = tolower(a[1])
      if (length(first) == 4 && substr(first, 1, 2) == "ff") return 0
      return 1
    }
    { ok = ($0 ~ /^[0-9.]+$/) ? v4($0) : v6($0); exit(ok ? 0 : 1) }'
  then
    die "$1 is not a usable IPv4/IPv6 address"
  fi
}

# The group the coturn container runs with (docker-compose.yml: user COTURN_UID:COTURN_GID).
COTURN_GID=$(env_value COTURN_GID)
COTURN_GID=${COTURN_GID:-3478}
case $COTURN_GID in
  '' | 0* | *[!0-9]*) die "COTURN_GID must be a number from 1 to 2147483647 (got '$COTURN_GID')" ;;
esac
[ "${#COTURN_GID}" -le 10 ] && [ "$COTURN_GID" -le 2147483647 ] || die "COTURN_GID is too large"
[ "$COTURN_GID" != 65534 ] || die "COTURN_GID=65534 is nogroup, shared with other host daemons; use a group of its own (default 3478)"
# Checked before anything is written: the group that will be able to read the secret.
if [ -n "${TURN_CONF_GROUP:-}" ]; then
  case $TURN_CONF_GROUP in
    *[!A-Za-z0-9._-]*) die "TURN_CONF_GROUP has characters that are not allowed here" ;;
    65534 | nogroup | nobody)
      die "TURN_CONF_GROUP=$TURN_CONF_GROUP is the host's shared nogroup: other daemons in it could read the TURN secret. Use the coturn group: TURN_CONF_GROUP=$COTURN_GID (COTURN_GID in .env)" ;;
    *[!0-9]*)
      echo "warning: TURN_CONF_GROUP=$TURN_CONF_GROUP is a name; make sure its GID is $COTURN_GID (COTURN_GID), the group coturn runs with" >&2 ;;
    *)
      [ "$TURN_CONF_GROUP" = "$COTURN_GID" ] ||
        die "TURN_CONF_GROUP=$TURN_CONF_GROUP, but coturn runs with group $COTURN_GID (COTURN_GID in .env, default 3478): it could not read the file" ;;
  esac
fi

TURN_REALM=$(env_value TURN_REALM)
TURN_EXTERNAL_IP=$(env_value TURN_EXTERNAL_IP)
TURN_LISTENING_IP=$(env_value TURN_LISTENING_IP)   # optional
TURN_RELAY_IP=$(env_value TURN_RELAY_IP)
TURN_MIN_PORT=$(env_value TURN_MIN_PORT)
TURN_MAX_PORT=$(env_value TURN_MAX_PORT)

# The secret file must hold exactly one line (one trailing line end is fine) of safe
# characters. Several lines are an error: they are never joined into one secret.
secret_file="$deploy/secrets/turn_secret"
lines=$(awk 'END { print NR }' "$secret_file")
[ "$lines" = 1 ] || die "secrets/turn_secret must contain exactly one line (found $lines)"
stray=$(LC_ALL=C tr -d 'A-Za-z0-9._~+/=\r\n-' < "$secret_file" | wc -c)
[ "$stray" -eq 0 ] || die "secrets/turn_secret has characters that are not allowed here"
TURN_SECRET=$(head -n 1 "$secret_file")
cr=$(printf '\r')
TURN_SECRET=${TURN_SECRET%"$cr"}   # a Windows line end

check TURN_REALM "$TURN_REALM" '[A-Za-z0-9.-]+'
# TURN_EXTERNAL_IP is one address, or "public/private" (behind NAT; coturn's external-ip syntax):
# each half is checked as an address on its own, and there may be only one slash.
case $TURN_EXTERNAL_IP in
  */*/*) die "TURN_EXTERNAL_IP has more than one slash" ;;
  */*)
    check_ip "TURN_EXTERNAL_IP (public part)" "${TURN_EXTERNAL_IP%%/*}"
    check_ip "TURN_EXTERNAL_IP (private part)" "${TURN_EXTERNAL_IP#*/}"
    ;;
  *) check_ip TURN_EXTERNAL_IP "$TURN_EXTERNAL_IP" ;;
esac
check_ip TURN_RELAY_IP "$TURN_RELAY_IP"
# Optional: listen only on this local address. Empty or missing = all addresses.
if [ -n "$TURN_LISTENING_IP" ]; then
  check_ip TURN_LISTENING_IP "$TURN_LISTENING_IP"
  TURN_LISTENING_IP_LINE="listening-ip=$TURN_LISTENING_IP"
else
  TURN_LISTENING_IP_LINE="# listening-ip not set: coturn listens on every address of the host"
fi
# Ports: 1-65535, no leading zero (so the shell never reads them as octal numbers).
check TURN_MIN_PORT "$TURN_MIN_PORT" '[1-9][0-9]{0,4}'
check TURN_MAX_PORT "$TURN_MAX_PORT" '[1-9][0-9]{0,4}'
[ "$TURN_MIN_PORT" -le 65535 ] || die "TURN_MIN_PORT must be at most 65535"
[ "$TURN_MAX_PORT" -le 65535 ] || die "TURN_MAX_PORT must be at most 65535"
[ "$TURN_MIN_PORT" -le "$TURN_MAX_PORT" ] || die "TURN_MIN_PORT must not be above TURN_MAX_PORT"
# The secret: at least 16 characters, from a safe set (openssl rand -hex 32 fits).
check "secrets/turn_secret" "$TURN_SECRET" '[A-Za-z0-9._~+/=-]{16,}'
# total-quota: 80 % of the relay ports (one port per allocation), at least 1. A quota above the
# number of ports could never trigger (relay port exhaustion, see the template).
TURN_TOTAL_QUOTA=$(( (TURN_MAX_PORT - TURN_MIN_PORT + 1) * 8 / 10 ))
[ "$TURN_TOTAL_QUOTA" -ge 1 ] || TURN_TOTAL_QUOTA=1

out="$here/turnserver.conf"
umask 077   # the file contains the shared secret
tmp=$(mktemp "$here/.turnserver.conf.XXXXXX") || die "cannot create a temporary file in $here"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
chmod 600 "$tmp"
# The values travel in the environment of awk and are inserted as literal text.
TURN_REALM="$TURN_REALM" TURN_EXTERNAL_IP="$TURN_EXTERNAL_IP" TURN_RELAY_IP="$TURN_RELAY_IP" \
TURN_MIN_PORT="$TURN_MIN_PORT" TURN_MAX_PORT="$TURN_MAX_PORT" TURN_SECRET="$TURN_SECRET" \
TURN_TOTAL_QUOTA="$TURN_TOTAL_QUOTA" TURN_LISTENING_IP_LINE="$TURN_LISTENING_IP_LINE" \
awk '
  function lit(line, name,    token, val, out, i) {
    token = "@" name "@"; val = ENVIRON[name]; out = ""
    while ((i = index(line, token)) > 0) {
      out = out substr(line, 1, i - 1) val
      line = substr(line, i + length(token))
    }
    return out line
  }
  {
    $0 = lit($0, "TURN_REALM"); $0 = lit($0, "TURN_EXTERNAL_IP"); $0 = lit($0, "TURN_RELAY_IP")
    $0 = lit($0, "TURN_MIN_PORT"); $0 = lit($0, "TURN_MAX_PORT"); $0 = lit($0, "TURN_SECRET")
    $0 = lit($0, "TURN_TOTAL_QUOTA"); $0 = lit($0, "TURN_LISTENING_IP_LINE")
    print
  }' "$here/turnserver.conf.template" > "$tmp"
# Replace the old file in one step; the new one keeps mode 600 whatever the old one had.
mv -f "$tmp" "$out"
chmod 600 "$out"
trap - EXIT HUP INT TERM
# The coturn container does not run as root (docker-compose.yml: user COTURN_UID:COTURN_GID, default
# 3478:3478) and cannot read a root-only 600 file: coturn then does not stop, it prints "Cannot find
# config file" and starts with its DEFAULTS (found in the first run). So:
# TURN_CONF_GROUP=3478 deploy/coturn/render.sh (needs root, or membership of that group) gives the file
# to that group with mode 640, and certs/privkey.pem too when it exists (its owner is left alone: it
# must stay 65532, the server). Without TURN_CONF_GROUP the mode stays 600.
if [ -n "${TURN_CONF_GROUP:-}" ]; then
  chgrp "$TURN_CONF_GROUP" "$out" || die "cannot chgrp $out to $TURN_CONF_GROUP (run as root?)"
  chmod 640 "$out"
  echo "mode 640, group $TURN_CONF_GROUP"
  key="$deploy/certs/privkey.pem"
  if [ -f "$key" ]; then
    chgrp "$TURN_CONF_GROUP" "$key" || die "cannot chgrp $key to $TURN_CONF_GROUP (run as root?)"
    chmod 640 "$key"
    echo "certs/privkey.pem: mode 640, group $TURN_CONF_GROUP (owner unchanged; the server needs owner 65532)"
  fi
else
  echo "note: mode 600; the coturn container (group $COTURN_GID) cannot read it. Run again with TURN_CONF_GROUP=$COTURN_GID (as root) before docker compose up." >&2
fi
echo "wrote $out"
