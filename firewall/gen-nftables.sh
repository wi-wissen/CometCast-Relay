#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Generates the nftables files from their templates, with the ports of THIS host filled in:
#   firewall/nftables.conf.in       -> <out-dir>/nftables.conf        (host firewall: SSH, HTTP/HTTPS, STUN, DHCP)
#   firewall/stun-ratelimit.nft.in  -> <out-dir>/stun-ratelimit.nft   (per-source and global STUN rate limit)
# Nothing is loaded or changed on the host; it only writes the two files (and, with --check, runs `nft -c`).
#
# Usage: firewall/gen-nftables.sh [--ssh-port N[,N...]] [--stun-port N] [--out-dir DIR] [--check]
#   --ssh-port  TCP port(s) of sshd. Default: detected (the port of your current SSH session, `sshd -T` as root,
#               the listening sshd sockets, sshd_config, else 22). A wrong port locks you out: read the line
#               "SSH ports: ..." this script prints, and keep a second session open when loading the file.
#   --stun-port UDP port of the STUN service (default: STUN_PORT in .env, else 3478)
#   --out-dir   default firewall/generated (ignored by git)
#   --check     run `nft -c -f` on the generated files (needs nft and root)
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../scripts/lib.sh
. "$here/../scripts/lib.sh"

ssh_ports=${SSH_PORT:-}
stun_port=
out=$here/generated
check=0
while [ $# -gt 0 ]; do
  case $1 in
    --ssh-port | --stun-port | --out-dir)
      [ $# -ge 2 ] || die "$1 needs a value"
      case $1 in
        --ssh-port) ssh_ports=$2 ;;
        --stun-port) stun_port=$2 ;;
        --out-dir) out=$2 ;;
      esac
      shift
      ;;
    --check) check=1 ;;
    -h | --help)
      sed -n '2,16p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

source_of_ssh="given"
if [ -z "$ssh_ports" ]; then
  ssh_ports=$(detect_ssh_ports)
  source_of_ssh="detected"
fi
[ -n "$stun_port" ] || stun_port=$(env_get STUN_PORT)
[ -n "$stun_port" ] || stun_port=3478

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
IFS=, read -r -a plist <<<"$ssh_ports"
[ "${#plist[@]}" -gt 0 ] || die "no SSH port"
for p in "${plist[@]}"; do valid_port "$p" || die "'$p' is not a TCP port (--ssh-port N[,N...])"; done
valid_port "$stun_port" || die "'$stun_port' is not a port (--stun-port N)"
ssh_set=${ssh_ports//,/, }

mkdir -p "$out"
gen() {
  sed -e "s/@SSH_PORTS@/$ssh_set/g" -e "s/@STUN_PORT@/$stun_port/g" "$1" >"$2"
  if grep -q '@[A-Z_]*@' "$2"; then die "unreplaced placeholder in $2"; fi
}
gen "$here/nftables.conf.in" "$out/nftables.conf"
gen "$here/stun-ratelimit.nft.in" "$out/stun-ratelimit.nft"

info "SSH ports: $ssh_ports ($source_of_ssh); STUN port: udp/$stun_port"
info "wrote $out/nftables.conf and $out/stun-ratelimit.nft"
if [ "$check" -eq 1 ]; then
  need_cmd nft
  nft -c -f "$out/nftables.conf"
  nft -c -f "$out/stun-ratelimit.nft"
  info "nft -c: both files are valid"
else
  info "check:  sudo nft -c -f $out/nftables.conf && sudo nft -c -f $out/stun-ratelimit.nft"
  info "apply:  sudo nft -f $out/nftables.conf && sudo nft -f $out/stun-ratelimit.nft   (second SSH session open!)"
fi
