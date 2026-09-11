#!/usr/bin/env bash
#
# End-to-end test of the deployment, without Avorion.
#
# tools/fakeserver.lua runs the real bridge.lua against a throwaway directory, so the
# game half of the transport is the actual mod code. This points the real Docker stack at
# that directory and checks both that a request round-trips and that the two ways a
# deployment usually breaks report themselves clearly.
#
# What it does NOT cover is Avorion's io.open sandbox - plain Lua opens anything - so it
# tests mounts, ownership and the HTTP bridge, not path security. tests/test_paths.lua
# covers that half.
#
#   tools/e2e.sh
#
# Needs docker and lua. Leaves nothing behind.

set -uo pipefail

cd "$(dirname "$0")/.."

PORT="${E2E_PORT:-18080}"
WORK="$(mktemp -d)"
GALAXY="$WORK/galaxy"
COMPOSE=(docker compose --env-file "$WORK/env" -f docker/docker-compose.yml)

failures=0

check() {
    if [ "$1" = "0" ]; then
        printf '  ok   %s\n' "$2"
    else
        failures=$((failures + 1))
        printf '  FAIL %s\n' "$2"
        [ -n "${3:-}" ] && printf '       > %s\n' "$3"
    fi
}

# The root-owned directories Docker leaves behind cannot be removed by this user.
cleanup() {
    "${COMPOSE[@]}" down -v >/dev/null 2>&1
    [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null
    docker run --rm -v "$GALAXY:/g" alpine rm -rf /g/moddata >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$GALAXY"
cat > "$WORK/env" <<EOF
GALAXY_DIR=$GALAXY
HTTP_PORT=$PORT
HTTPS_PORT=$((PORT + 1))
BRIDGE_USER=$(id -u):$(id -g)
EOF

call() {
    curl -s -m 40 -o "$WORK/body" -w '%{http_code}' -H "X-API-Key: ${1:-none}" \
        "http://127.0.0.1:$PORT/ping"
}

code() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("error",{}).get("code",""))' "$WORK/body" 2>/dev/null; }

wipe() { docker run --rm -v "$GALAXY:/g" alpine rm -rf /g/moddata >/dev/null 2>&1; }

echo "building"
"${COMPOSE[@]}" build >/dev/null 2>&1 || { echo "build failed"; exit 1; }

# #### A deployment pointed at nothing #### --
#
# Docker creates a missing bind-mount source itself, so this is the silent failure the
# preflight exists to make loud.

echo
echo "GALAXY_DIR pointing where the mod never wrote"
wipe
"${COMPOSE[@]}" up -d >/dev/null 2>&1
sleep 6
status="$(call)"
check "$([ "$status" = "503" ] && echo 0 || echo 1)" "an empty galaxy directory is a 503, not a timeout" "got $status"
check "$([ "$(code)" = "bridge_unavailable" ] && echo 0 || echo 1)" "it reports bridge_unavailable" "got $(code)"

# #### Directories Docker made rather than the mod #### --

echo
echo "transport directory owned by root"
"${COMPOSE[@]}" down >/dev/null 2>&1
wipe
docker run --rm -v "$GALAXY:/g" alpine \
    mkdir -p /g/moddata/AutomationAPI/requests /g/moddata/AutomationAPI/responses >/dev/null 2>&1
"${COMPOSE[@]}" up -d >/dev/null 2>&1
sleep 6
status="$(call)"
check "$([ "$(code)" = "transport_not_writable" ] && echo 0 || echo 1)" \
    "a root-owned transport directory names itself" "got $status $(code)"

# #### The real thing #### --

echo
echo "round trip"
"${COMPOSE[@]}" down >/dev/null 2>&1
wipe

MOCK_ROOT="$GALAXY" lua tools/fakeserver.lua > "$WORK/fake.log" 2>&1 &
FAKE_PID=$!
sleep 3
KEY="$(grep -o 'avo_[a-f0-9]*' "$WORK/fake.log" | head -1)"
check "$([ -n "$KEY" ] && echo 0 || echo 1)" "the fake server came up and issued a key"

"${COMPOSE[@]}" up -d >/dev/null 2>&1
sleep 6

status="$(call "$KEY")"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" "GET /ping round-trips through the file transport" "got $status: $(head -c 200 "$WORK/body")"
check "$(grep -q '"api":1' "$WORK/body" && echo 0 || echo 1)" "the response is the mod's own envelope"

status="$(call bogus)"
check "$([ "$status" = "401" ] && echo 0 || echo 1)" "an unknown key is rejected by the mod, not the bridge" "got $status"

# #### Self-healing #### --
#
# The mod re-creates its directories every 30s. A bind mount binds an inode, so mounting
# requests/ and responses/ directly would leave the container holding the deleted one.

echo
echo "directories removed under a running stack"
rm -rf "$GALAXY/moddata/AutomationAPI/requests"
sleep 35
status="$(call "$KEY")"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" \
    "the mod re-creates the directory and the bridge follows it, without a restart" "got $status: $(code)"

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
