#!/bin/sh
# Tests of an AIrtg collector image, deployed with compose.yaml as the
# README describes it.
#
#   scripts/test.sh IMAGE
#
# snmp-poller: version, non-root user, the shipped configuration is valid,
# and the compose service starts with the deployment directories, encrypts
# the credentials of conf.d in place, writes data/ and logs/ as the
# deployment user, and stops cleanly.
set -eu

if [ $# -ne 1 ]; then
	echo "usage: scripts/test.sh IMAGE" >&2
	exit 2
fi
image=$1
docker=${DOCKER:-docker}
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
project=airtg-collector-test-$$
compose() { $docker compose --project-directory "$tmp" -p "$project" -f "$tmp/compose.yaml" -f "$tmp/compose.test.yaml" "$@"; }
cleanup() {
	compose down -t 1 >/dev/null 2>&1 || true
	rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	compose logs --no-log-prefix 2>&1 | sed 's/^/  | /' >&2 || true
	exit 1
}
ok() { echo "ok: $*"; }
logs() { compose logs --no-log-prefix snmp-poller 2>&1; }

# Retries a command for up to 30s.
eventually() {
	i=0
	until "$@" >/dev/null 2>&1; do
		i=$((i + 1))
		[ $i -lt 60 ] || return 1
		sleep 0.5
	done
}

want=$($docker image inspect -f '{{index .Config.Labels "io.airtg.snmp-poller.version"}}' "$image")
got=$($docker run --rm "$image" snmp-poller -version)
case $got in
"AIrtg snmp-poller $want "*) ok "snmp-poller -version: $got" ;;
*) fail "snmp-poller -version: got '$got', want AIrtg snmp-poller $want" ;;
esac

uid=$($docker run --rm "$image" id -u)
[ "$uid" = 10001 ] || fail "runs as uid $uid by default, want 10001"
ok "runs as uid 10001 by default"

$docker run --rm "$image" snmp-poller -check >/dev/null || fail "snmp-poller -check of the shipped configuration"
ok "shipped configuration is valid"

# The deployment directory of the README, with this image. The device does
# not answer: its polls fail, which is fine here.
cp "$root/compose.yaml" "$tmp/"
cat >"$tmp/compose.test.yaml" <<EOF
services:
  snmp-poller:
    image: $image
    pull_policy: never
EOF
mkdir -p "$tmp/snmp-poller/conf.d" "$tmp/snmp-poller/data" "$tmp/snmp-poller/logs"
printf 'AIRTG_UID=%s\nAIRTG_GID=%s\n' "$(id -u)" "$(id -g)" >"$tmp/.env"
cat >"$tmp/snmp-poller/conf.d/devices.yaml" <<'EOF'
devices:
  - id: test-device
    address: 127.0.0.1
    port: 16100
    poll_interval: 5s
    snmp:
      version: 2c
      community: test-community-secret
EOF

compose up -d || fail "docker compose up"

started() { logs | grep -q 'msg="poller started"'; }
eventually started || fail "no 'poller started' log line"
logs | grep -q 'msg="poller started" devices=1' || fail "the conf.d device is not loaded"
ok "compose service started with the conf.d device"

devices=$tmp/snmp-poller/conf.d/devices.yaml
sealed() { grep -q 'community: ~~[0-9A-Fa-f]*~~' "$devices"; }
eventually sealed || fail "community not encrypted in conf.d/devices.yaml: $(cat "$devices")"
! grep -q test-community-secret "$devices" || fail "clear-text community left in conf.d/devices.yaml"
! logs | grep -q test-community-secret || fail "community logged"
[ -n "$(find "$devices" -prune -user "$(id -u)")" ] || fail "conf.d/devices.yaml is no longer owned by the deployment user (uid $(id -u))"
ok "conf.d credentials encrypted in place, still owned by the deployment user, not logged"

[ -s "$tmp/snmp-poller/data/key.dat" ] || fail "no snmp-poller/data/key.dat"
[ -s "$tmp/snmp-poller/logs/snmp-poller.log" ] || fail "no snmp-poller/logs/snmp-poller.log"
ok "snmp-poller/data/key.dat and snmp-poller/logs/snmp-poller.log written"

compose stop snmp-poller >/dev/null 2>&1
code=$($docker inspect -f '{{.State.ExitCode}}' "$(compose ps -aq snmp-poller)")
[ "$code" = 0 ] || fail "exit code $code after docker compose stop, want 0"
logs | grep -q 'msg="poller stopped"' || fail "no 'poller stopped' log line"
ok "stopped cleanly"

echo "all tests passed: $image"
