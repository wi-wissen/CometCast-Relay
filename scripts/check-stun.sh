#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Starts the STUN image of compose.yaml with config/stun.conf on a throw-away container (loopback only,
# same hardening flags as the compose service) and checks it with scripts/stun-check.py: it must
# start without configuration problems, answer a Binding request, stay SILENT for a TURN Allocate request and
# for garbage, and not amplify malformed requests. Then a POSITIVE CONTROL: the same image as a normal TURN
# server (long-term credentials) must FAIL the Allocate check (it answers 401), which proves that the check
# can fail. Needs Docker and python3; used by CI and by hand after changing config/stun.conf or the image.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_cmd docker
need_cmd python3

# The image of the "stun" service (the line right after "  stun:" that starts with "image:").
image=$(awk '/^  stun:[[:space:]]*$/ { in_s = 1; next } in_s && /^    image:/ { print $2; exit }' "$ROOT/compose.yaml")
[ -n "$image" ] || die "cannot find the stun image in compose.yaml"
port=${CHECK_STUN_PORT:-13478}
name=cometcast-relay-check-stun-$$
name_ctl=$name-control
work=$(mktemp -d)

cleanup() {
  docker rm -f "$name" "$name_ctl" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# start_coturn NAME HOSTPORT CONFIG: same flags as the compose service.
start_coturn() {
  docker run -d --name "$1" \
    -p "127.0.0.1:$2:3478/udp" \
    --read-only --tmpfs /tmp --tmpfs /var/tmp \
    --cap-drop ALL --cap-add NET_BIND_SERVICE --security-opt no-new-privileges:true \
    -v "$3:/etc/coturn/turnserver.conf:ro" \
    "$image" -c /etc/coturn/turnserver.conf >/dev/null
}

# wait_up NAME: wait until coturn has logged that it is up (or has stopped). The log is read into a variable
# and searched there: `docker logs | grep -q` under pipefail fails at random when grep exits first (SIGPIPE).
wait_up() {
  local logs
  for _ in $(seq 1 30); do
    logs=$(docker logs "$1" 2>&1 || true)
    if grep -q 'prometheus collector disabled' <<<"$logs"; then return 0; fi
    [ "$(docker inspect -f '{{.State.Running}}' "$1")" = true ] || return 0
    sleep 1
  done
}

start_coturn "$name" "$port" "$ROOT/config/stun.conf"
wait_up "$name"
logs=$(docker logs "$name" 2>&1 || true)
if [ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]; then
  tail -n 20 <<<"$logs"
  die "the STUN container stopped; see the log above"
fi
# coturn does not stop for an unknown option: it logs "WARNING Bad configuration format" and carries on. A deprecated
# option is not always logged as ERROR, so any line with "deprecated" (any case) counts too.
problems='Bad configuration format|CONFIG ERROR|ERROR|[Dd][Ee][Pp][Rr][Ee][Cc][Aa][Tt][Ee][Dd]'
if grep -Eq "$problems" <<<"$logs"; then
  grep -E "$problems" <<<"$logs"
  die "coturn reported a configuration problem (an option that this coturn version does not know, or a deprecated one?)"
fi
ok "coturn started with config/stun.conf without configuration problems"

if python3 -I "$ROOT/scripts/stun-check.py" --host 127.0.0.1 --port "$port"; then
  ok "STUN-only behaviour confirmed"
else
  die "stun-check.py failed"
fi

# Positive control: a normal TURN server (credentials required) must fail the same check.
cat >"$work/turn.conf" <<'CONF'
listening-port=3478
no-tls
lt-cred-mech
realm=check.invalid
user=check:check
pidfile=/tmp/turnserver.pid
log-file=stdout
simple-log
CONF
chmod 0644 "$work/turn.conf"
ctl_port=$((port + 1))
start_coturn "$name_ctl" "$ctl_port" "$work/turn.conf"
wait_up "$name_ctl"
ctl_out=$(python3 -I "$ROOT/scripts/stun-check.py" --host 127.0.0.1 --port "$ctl_port" 2>&1) && ctl_rc=0 || ctl_rc=$?
if [ "$ctl_rc" -ne 0 ] && grep -q '^FAIL allocate: answered with TURN error 401' <<<"$ctl_out"; then
  ok "positive control: a normal TURN server fails the Allocate check as it must (answers 401)"
else
  printf '%s\n' "$ctl_out"
  die "positive control failed: stun-check.py did not reject a normal TURN server (exit $ctl_rc); the Allocate check proves nothing"
fi
