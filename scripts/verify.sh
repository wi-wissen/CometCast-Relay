#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Pass/fail checks of a running relay. Run it on the host after every start and update, and from
# another machine (--no-compose) as a simple outside check.
# Exit code: 0 = all passed, 1 = a CORE check failed (the relay itself: containers, TLS, /healthz, ALTCHA, CORS,
# the WebSocket handshake, the server serves no web files), 2 = only STUN checks failed (STUN container, the
# /ice-servers list, the UDP checks). update.sh rolls back on 1 and only warns on 2.
#
# Usage: scripts/verify.sh [options]
#   --domain NAME     relay host name (default: RELAY_DOMAIN from .env, else relay.cometcast.de)
#   --origin URL      browser origin to test CORS with (default: first allowed_origins entry of config/relay.toml)
#   --ip ADDR         connect to this address instead of resolving the name (tests before DNS is switched, or a local run)
#   --port N          HTTPS port (default: HTTPS_PORT from .env, else 443)
#   --http-port N     HTTP port for the redirect check (default: HTTP_PORT from .env, else 80)
#   --cacert FILE     CA certificate to trust (local tests with a private CA)
#   --min-days N      the certificate must be valid for at least N more days (default 14)
#   --stun-host NAME  host of the STUN service (default: host of the first [stun] url from /ice-servers)
#   --stun-port N     UDP port of the STUN service (default: port of that url; with --ip also STUN_PORT from .env)
#   --only core|stun|all  run only the core checks, only the STUN checks, or both (default all)
#   --no-udp          skip the UDP STUN checks (from a network that blocks UDP; the list itself is still checked)
#   --no-compose      skip the docker compose checks (use when run from another machine)
#   --quiet-header    do not print the heading (used by update.sh)
# Note: the WebSocket check opens three connections; the server allows 30 new connections per minute and
# address (open mode), so do not run verify.sh in a tight loop from one address.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

domain=
origin=
ip=
port=443
http_port=80
cacert=
stun_host=
stun_port=
check_udp=1
min_days=14
only=all
use_compose=1
header=1
while [ $# -gt 0 ]; do
  case $1 in
    --domain | --origin | --ip | --port | --http-port | --cacert | --min-days | --stun-host | --stun-port | --only)
      [ $# -ge 2 ] || die "$1 needs a value"
      case $1 in
        --domain) domain=$2 ;;
        --origin) origin=$2 ;;
        --ip) ip=$2 ;;
        --port) port=$2 ;;
        --http-port) http_port=$2 ;;
        --cacert) cacert=$2 ;;
        --min-days) min_days=$2 ;;
        --stun-host) stun_host=$2 ;;
        --stun-port) stun_port=$2 ;;
        --only) only=$2 ;;
      esac
      shift
      ;;
    --no-udp) check_udp=0 ;;
    --no-compose) use_compose=0 ;;
    --quiet-header) header=0 ;;
    -h | --help)
      sed -n '2,26p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# Defaults from .env (the host side of the published ports), so a non-standard setup needs no flags.
if [ "$port" = 443 ] && [ -n "$(env_get HTTPS_PORT)" ]; then port=$(env_get HTTPS_PORT); fi
if [ "$http_port" = 80 ] && [ -n "$(env_get HTTP_PORT)" ]; then http_port=$(env_get HTTP_PORT); fi
if [ -z "$ip" ] && [ "$use_compose" -eq 1 ] && [ -n "$(env_get BIND_ADDR)" ] && [ "$(env_get BIND_ADDR)" != 0.0.0.0 ]; then
  ip=$(env_get BIND_ADDR)
fi
[ -n "$domain" ] || domain=$(env_get RELAY_DOMAIN)
[ -n "$domain" ] || domain=relay.cometcast.de
if [ -z "$origin" ] && [ -f "$ROOT/config/relay.toml" ]; then
  origin=$(sed -e 's/[[:space:]]*#.*$//' "$ROOT/config/relay.toml" | grep -E '^allowed_origins' | grep -oE 'https?://[^"]+' | head -n 1 || true)
fi
[ -n "$origin" ] || die "no --origin given and none found in config/relay.toml"
[[ $port =~ ^[0-9]+$ && $http_port =~ ^[0-9]+$ && $min_days =~ ^[0-9]+$ ]] || die "ports and --min-days must be numbers"
[[ -z $stun_port || $stun_port =~ ^[0-9]+$ ]] || die "--stun-port must be a number"
case $only in core | stun | all) ;; *) die "--only must be core, stun or all" ;; esac
do_core=0
do_stun=0
[ "$only" = stun ] || do_core=1
[ "$only" = core ] || do_stun=1
need_cmd curl
need_cmd python3

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bad_origin=https://not-allowed.invalid
base=https://$domain
[ "$port" = 443 ] || base=$base:$port
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl_args=(-sS --max-time 15 --proto '=https,http')
[ -z "$cacert" ] || curl_args+=(--cacert "$cacert")
[ -z "$ip" ] || curl_args+=(--resolve "$domain:$port:$ip" --resolve "$domain:$http_port:$ip")

# req NAME [curl args...] URL: stores status in $tmp/NAME.code, headers in NAME.h, body in NAME.b
req() {
  local name=$1
  shift
  local code
  if code=$(curl "${curl_args[@]}" -o "$tmp/$name.b" -D "$tmp/$name.h" -w '%{http_code}' "$@" 2>"$tmp/$name.err"); then
    printf '%s' "$code" >"$tmp/$name.code"
  else
    printf '000' >"$tmp/$name.code"
  fi
}
code_of() { cat "$tmp/$1.code"; }
# header NAME HEADER: value of a response header (case-insensitive), without CR
header_of() { grep -i "^$2:" "$tmp/$1.h" 2>/dev/null | head -n 1 | cut -d: -f2- | tr -d '\r' | sed -e 's/^[[:space:]]*//' || true; }

if [ "$header" -eq 1 ]; then
  info "Verifying $base (origin for CORS tests: $origin)${ip:+, connecting to $ip}"
fi

# Checks are in two classes (CLASS in lib.sh): core = the relay itself, stun = the STUN service and the list
# that announces it. The exit code tells them apart (see the heading of this file).

# 1. containers
compose_ok=0
if [ "$use_compose" -eq 1 ]; then
  if have_cmd docker && docker compose version >/dev/null 2>&1 && [ -f "$ROOT/.env" ]; then
    compose_ok=1
    services=()
    [ "$do_core" -eq 0 ] || services+=(cometcast-server caddy)
    [ "$do_stun" -eq 0 ] || services+=(stun)
    for svc in "${services[@]}"; do
      CLASS=core
      [ "$svc" != stun ] || CLASS=stun
      state=$(compose ps --format '{{.Health}}' "$svc" 2>/dev/null | head -n 1 || true)
      if [ "$state" = healthy ]; then
        ok "container $svc is healthy"
      else
        fail "container $svc is not healthy (state: ${state:-not running}); docker compose ps, docker compose logs $svc"
      fi
    done
    CLASS=core
  else
    warn "docker compose not usable here: container checks skipped"
  fi
fi

# 2. TLS certificate (core). -verify_hostname makes openssl check that the certificate is valid for the NAME, also
# when --ip connects to an address: without it s_client verifies the chain only.
if [ "$do_core" -eq 1 ] && have_cmd openssl; then
  host_for_tls=${ip:-$domain}
  ossl=(openssl s_client -connect "$host_for_tls:$port" -servername "$domain" -verify_hostname "$domain" -verify_return_error)
  [ -z "$cacert" ] || ossl+=(-CAfile "$cacert")
  if "${ossl[@]}" </dev/null >"$tmp/tls.out" 2>"$tmp/tls.err"; then
    ok "TLS: certificate chain verifies and is valid for the name $domain"
    if openssl x509 -noout -checkend $((min_days * 86400)) <"$tmp/tls.out" >/dev/null 2>&1; then
      ok "TLS: certificate valid for at least $min_days more days"
    else
      fail "TLS: certificate expires within $min_days days (Caddy should renew it; docker compose logs caddy)"
    fi
  else
    fail "TLS: handshake or certificate verification failed ($(grep -m1 -i 'verify error\|error' "$tmp/tls.err" "$tmp/tls.out" 2>/dev/null | head -n 1 | cut -c1-150))"
  fi
elif [ "$do_core" -eq 1 ]; then
  warn "openssl missing: certificate not checked separately"
fi

if [ "$do_core" -eq 1 ]; then
# 3. health endpoint
req health "$base/healthz"
if [ "$(code_of health)" = 200 ] && [ "$(tr -d '\r\n' <"$tmp/health.b")" = ok ]; then
  ok "GET /healthz -> 200 ok"
else
  fail "GET /healthz -> $(code_of health) (expected 200 ok) $(head -c 150 "$tmp/health.err")"
fi

# 4. HTTP redirects to HTTPS
req redirect --max-redirs 0 "http://$domain:$http_port/healthz"
case $(code_of redirect) in
  301 | 302 | 307 | 308)
    loc=$(header_of redirect location)
    if [[ $loc == https://$domain* ]]; then
      ok "HTTP :$http_port redirects to HTTPS ($loc)"
    else
      fail "HTTP redirect goes somewhere unexpected: $loc"
    fi
    ;;
  *) fail "HTTP :$http_port did not redirect (code $(code_of redirect))" ;;
esac

# 5. paths that must not exist on the public relay
req root "$base/"
if [ "$(code_of root)" = 404 ]; then
  ok "GET / -> 404 (the bundled web app is not exposed)"
else
  fail "GET / -> $(code_of root) (expected 404; is the Caddyfile path allowlist in place?)"
fi
# 5a. the server itself must not serve web files (core). The Docker image presets COMETCAST_WEB_DIR to the bundled web
# app; compose.yaml sets it empty, which a server from MIN_SERVER_VERSION on reads as "none". Asked directly on the
# backend from inside the caddy container (not through Caddy's path allowlist): "/" and other unknown paths must be
# 404 from the server itself. Skipped without docker compose (--no-compose).
if [ "$compose_ok" -eq 1 ]; then
  backend_bad=
  for path in / /index.html /WS; do
    bout=$(compose exec -T caddy wget -S -O /dev/null "http://cometcast-server:8443$path" 2>&1 || true)
    bcode=$(sed -n 's/^[[:space:]]*HTTP\/[0-9.]* \([0-9]*\).*$/\1/p' <<<"$bout" | head -n 1)
    [ "$bcode" = 404 ] || backend_bad="$backend_bad $path=${bcode:-no-answer}"
  done
  if [ -z "$backend_bad" ]; then
    ok "the server itself answers 404 for /, /index.html and /WS (no web files, case-sensitive routes), asked directly on the backend"
  else
    fail "the server answers something else than 404 on the backend:$backend_bad (an image that serves its bundled web app, or a server older than MIN_SERVER_VERSION that does not read COMETCAST_WEB_DIR= as none?)"
  fi
fi
# 5a'. Caddy's path matchers are case-insensitive: /WS and /HEALTHZ pass the allowlist and reach the server, whose
# routes are case-sensitive. They must end as 404, not as the endpoint and not as a file.
req upper_ws "$base/WS"
req upper_hz "$base/HEALTHZ"
if [ "$(code_of upper_ws)" = 404 ] && [ "$(code_of upper_hz)" = 404 ]; then
  ok "non-canonical case (/WS, /HEALTHZ) -> 404"
else
  fail "non-canonical case: /WS -> $(code_of upper_ws), /HEALTHZ -> $(code_of upper_hz) (expected 404 for both)"
fi

fi

if [ "$do_stun" -eq 1 ]; then
CLASS=stun
# 5b. ICE servers: the public relay lists STUN only (no TURN, no credentials), with CORS for the web app
req ice -H "Origin: $origin" "$base/ice-servers"
stun_url=
if [ "$(code_of ice)" = 200 ]; then
  if ice_out=$(python3 -I - "$tmp/ice.b" "$ROOT/config/relay.toml" <<'PY' 2>&1
import json, re, sys
body = json.load(open(sys.argv[1]))
if not isinstance(body, list) or not body:
    sys.exit("expected a non-empty JSON array, got %r" % (body,))
urls = []
for e in body:
    if not isinstance(e, dict) or set(e) != {"urls"}:
        sys.exit("entry has fields other than urls (credentials or ttl must not be handed out here): %r" % (e,))
    if not isinstance(e["urls"], list) or not e["urls"]:
        sys.exit("urls must be a non-empty list: %r" % (e,))
    for u in e["urls"]:
        if not re.fullmatch(r"stuns?:[A-Za-z0-9.-]+(:[0-9]{1,5})?", u):
            sys.exit("not a plain STUN url: %r" % (u,))
        urls.append(u)
try:
    text = open(sys.argv[2]).read()
except OSError:
    text = ""
text = re.sub(r"(?m)#.*$", "", text)
m = re.search(r"(?ms)^\[stun\]\s*(.*?)(?=^\[|\Z)", text)
if m:
    want = re.findall(r'"([^"]*)"', (re.search(r"(?m)^urls\s*=\s*\[(.*?)\]", m.group(1), re.S) or [None, ""])[1])
    if want and want != urls:
        sys.exit("answer %r differs from [stun] urls in config/relay.toml %r" % (urls, want))
print(urls[0])
PY
  ); then
    stun_url=$ice_out
    ok "GET /ice-servers -> 200, STUN only without credentials ($stun_url)"
  else
    fail "GET /ice-servers -> 200 but $ice_out"
  fi
else
  fail "GET /ice-servers -> $(code_of ice) (expected 200 with the STUN list; server release without [stun] support, or no [stun] section? $(head -c 100 "$tmp/ice.b"))"
fi
if [ "$(header_of ice access-control-allow-origin)" = "$origin" ]; then
  ok "ice-servers answer allows origin $origin (Access-Control-Allow-Origin)"
else
  fail "ice-servers answer lacks Access-Control-Allow-Origin: $origin (got '$(header_of ice access-control-allow-origin)')"
fi
if header_of ice cache-control | grep -qi no-store; then
  ok "ice-servers answer has Cache-Control: no-store"
else
  fail "ice-servers answer is missing Cache-Control: no-store"
fi

# 5c. the STUN service itself, over UDP (a real Binding request; Allocate must not work)
if [ "$check_udp" -eq 0 ]; then
  warn "UDP STUN checks skipped (--no-udp)"
elif [ -z "$stun_url" ]; then
  warn "UDP STUN checks skipped: no valid STUN url from /ice-servers"
else
  hp=${stun_url#*:}
  url_host=${hp%%:*}
  url_port=3478
  [[ $hp == *:* ]] && url_port=${hp##*:}
  t_host=${stun_host:-${ip:-$url_host}}
  t_port=${stun_port:-$url_port}
  if [ -z "$stun_port" ] && [ -n "$ip" ] && [ -n "$(env_get STUN_PORT)" ]; then t_port=$(env_get STUN_PORT); fi
  if [[ $stun_url == stuns:* ]]; then
    warn "first STUN url is stuns: (TLS); the UDP checks need a stun: url, skipped"
  else
    stun_out=$(python3 -I "$here/stun-check.py" --host "$t_host" --port "$t_port" 2>&1) && stun_rc=0 || stun_rc=$?
    while IFS= read -r line; do
      case $line in
        ok\ *) ok "STUN $t_host:$t_port/udp ${line#ok }" ;;
        *) fail "STUN $t_host:$t_port/udp ${line#FAIL}" ;;
      esac
    done <<<"$stun_out"
    [ "$stun_rc" -eq 0 ] || [ -n "$stun_out" ] || fail "STUN check produced no output"
  fi
fi

CLASS=core
fi

if [ "$do_core" -eq 1 ]; then
# 6. ALTCHA challenge, with CORS
req altcha -H "Origin: $origin" "$base/altcha/challenge"
if [ "$(code_of altcha)" = 200 ] && grep -q '"parameters"' "$tmp/altcha.b" && grep -q '"signature"' "$tmp/altcha.b"; then
  ok "GET /altcha/challenge -> 200 with parameters and signature"
else
  fail "GET /altcha/challenge -> $(code_of altcha) without a puzzle: $(head -c 150 "$tmp/altcha.b")"
fi
if [ "$(header_of altcha access-control-allow-origin)" = "$origin" ]; then
  ok "challenge answer allows origin $origin (Access-Control-Allow-Origin)"
else
  fail "challenge answer lacks Access-Control-Allow-Origin: $origin (got '$(header_of altcha access-control-allow-origin)')"
fi
if header_of altcha cache-control | grep -qi no-store; then
  ok "challenge answer has Cache-Control: no-store"
else
  fail "challenge answer is missing Cache-Control: no-store"
fi

# 7. CORS preflight
req pre_ok -X OPTIONS -H "Origin: $origin" -H 'Access-Control-Request-Method: GET' "$base/altcha/challenge"
if [ "$(code_of pre_ok)" = 204 ] && [ "$(header_of pre_ok access-control-allow-origin)" = "$origin" ]; then
  ok "CORS preflight from $origin -> 204 and origin allowed"
else
  fail "CORS preflight from $origin -> $(code_of pre_ok), allow-origin '$(header_of pre_ok access-control-allow-origin)' (expected 204 and the origin)"
fi
req pre_bad -X OPTIONS -H "Origin: $bad_origin" -H 'Access-Control-Request-Method: GET' "$base/altcha/challenge"
if [ "$(code_of pre_bad)" = 403 ] && [ -z "$(header_of pre_bad access-control-allow-origin)" ]; then
  ok "CORS preflight from a foreign origin -> 403 without allow-origin"
else
  fail "CORS preflight from a foreign origin -> $(code_of pre_bad), allow-origin '$(header_of pre_bad access-control-allow-origin)' (expected 403 and none)"
fi

# 8. WebSocket
ws_args=(--host "$domain" --port "$port")
[ -z "$ip" ] || ws_args+=(--connect "$ip")
[ -z "$cacert" ] || ws_args+=(--cafile "$cacert")
if out=$(python3 -I "$here/ws-check.py" "${ws_args[@]}" --origin "$origin" --mode accept 2>&1); then
  ok "WebSocket /ws from $origin: $out"
else
  fail "WebSocket /ws from $origin: $out"
fi
if out=$(python3 -I "$here/ws-check.py" "${ws_args[@]}" --origin "$bad_origin" --mode reject 2>&1); then
  ok "WebSocket /ws from a foreign origin: $out"
else
  fail "WebSocket /ws from a foreign origin: $out"
fi
if out=$(python3 -I "$here/ws-check.py" "${ws_args[@]}" --mode accept 2>&1); then
  ok "WebSocket /ws without Origin (native client): $out"
else
  fail "WebSocket /ws without Origin (native client): $out"
fi

fi

info
info "Summary: $N_OK passed, $N_WARN warnings, $N_FAIL failed ($((N_FAIL - N_FAIL_STUN)) core, $N_FAIL_STUN STUN)."
if [ $((N_FAIL - N_FAIL_STUN)) -gt 0 ]; then exit 1; fi
if [ "$N_FAIL_STUN" -gt 0 ]; then exit 2; fi
exit 0
