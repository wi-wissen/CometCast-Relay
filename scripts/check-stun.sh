#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Starts the STUN image of compose.yaml with config/stun.conf on a throw-away container (loopback only,
# same hardening flags as the compose service) and checks it with scripts/stun-check.py: it must
# start without configuration errors, answer a Binding request, ignore a TURN Allocate request and not
# answer garbage. Needs Docker and python3; used by CI and by hand after changing config/stun.conf or the image.
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

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$name" \
  -p "127.0.0.1:$port:3478/udp" \
  --read-only --tmpfs /tmp --tmpfs /var/tmp \
  --cap-drop ALL --cap-add NET_BIND_SERVICE --security-opt no-new-privileges:true \
  -v "$ROOT/config/stun.conf:/etc/coturn/turnserver.conf:ro" \
  "$image" -c /etc/coturn/turnserver.conf >/dev/null

# Wait until coturn has logged that it is up (or has stopped).
for _ in $(seq 1 30); do
  if docker logs "$name" 2>&1 | grep -q 'prometheus collector disabled'; then break; fi
  [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || break
  sleep 1
done
logs=$(docker logs "$name" 2>&1 || true)
if [ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]; then
  printf '%s\n' "$logs" | tail -n 20
  die "the STUN container stopped; see the log above"
fi
if grep -Eq 'Bad configuration format|CONFIG ERROR|ERROR' <<<"$logs"; then
  grep -E 'Bad configuration format|CONFIG ERROR|ERROR' <<<"$logs"
  die "coturn reported a configuration problem (an option that this coturn version does not know?)"
fi
ok "coturn started with config/stun.conf without configuration errors"

if python3 -I "$ROOT/scripts/stun-check.py" --host 127.0.0.1 --port "$port"; then
  ok "STUN-only behaviour confirmed"
else
  die "stun-check.py failed"
fi
