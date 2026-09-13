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
POSTGRES_PASSWORD=e2e-throwaway-$$
# Short enough that the poller section does not have to wait half a minute to see a pass.
POLL_INTERVAL=5
EOF

call() {
    curl -s -m 40 -o "$WORK/body" -w '%{http_code}' -H "X-API-Key: ${1:-none}" \
        "http://127.0.0.1:$PORT/ping"
}

# Any path, unlike call() which is pinned to /ping so it can run without a key.
get() {
    curl -s -m 40 -o "$WORK/body" -w '%{http_code}' -H "X-API-Key: $1" \
        "http://127.0.0.1:$PORT$2"
}

json() { python3 -c "$1" "$WORK/body" 2>/dev/null; }

# Waits for the bridge to answer at all, whatever it answers.
#
# A fixed sleep was enough when the stack was one container. It is not now: compose holds
# the api back until Postgres reports healthy, and how long a first-time initdb takes
# depends on the machine. Every check below wants the bridge's answer, not a race with it.
await() {
    for _ in $(seq 1 "${1:-40}"); do
        curl -s -m 5 -o /dev/null -w '' "http://127.0.0.1:$PORT/ping" 2>/dev/null && return 0
        sleep 1
    done
    return 1
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
await
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
await
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
await

status="$(call "$KEY")"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" "GET /ping round-trips through the file transport" "got $status: $(head -c 200 "$WORK/body")"
check "$(grep -q '"api":1' "$WORK/body" && echo 0 || echo 1)" "the response is the mod's own envelope"

status="$(call bogus)"
check "$([ "$status" = "401" ] && echo 0 || echo 1)" "an unknown key is rejected by the mod, not the bridge" "got $status"

# #### The bridge's own history #### --
#
# Answered by the bridge rather than forwarded, and written as a side effect of relaying
# the two calls it is built from. Both halves are worth pinning here: the store is the one
# piece of logic on this side of the transport, so nothing on the mod side tests it.

echo
echo "history"

status="$(get "$KEY" /history/summary)"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" "a key with no history reads an empty summary" "got $status: $(head -c 200 "$WORK/body")"
check "$(json 'import json,sys;s=json.load(open(sys.argv[1]));sys.exit(0 if s["ships"]==[] else 1)' && echo 0 || echo 1)" \
    "with no craft in it"

status="$(get "$KEY" /ships)"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" "GET /ships round-trips" "got $status: $(head -c 200 "$WORK/body")"

status="$(get "$KEY" /history/summary)"
names="$(json 'import json,sys;print(",".join(sorted(s["name"] for s in json.load(open(sys.argv[1]))["ships"])))')"
check "$([ "$names" = "Ore Hound,Tug" ] && echo 0 || echo 1)" \
    "relaying that answer recorded both craft" "got '$names'"

status="$(get "$KEY" /history/heatmap)"
cells="$(json 'import json,sys;print(len(json.load(open(sys.argv[1]))["cells"]))')"
check "$([ "$cells" = "2" ] && echo 0 || echo 1)" "the heatmap holds one cell per occupied sector" "got $cells"

# A second identical poll must not double-count a fleet that has not moved.
get "$KEY" /ships >/dev/null
get "$KEY" /history/heatmap >/dev/null
visits="$(json 'import json,sys;print(sum(c["visits"] for c in json.load(open(sys.argv[1]))["cells"]))')"
check "$([ "$visits" = "2" ] && echo 0 || echo 1)" "polling a parked fleet again adds no visits" "got $visits"

status="$(get bogus /history/summary)"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" "an unknown key reads its own empty history" "got $status"
check "$(json 'import json,sys;s=json.load(open(sys.argv[1]));sys.exit(0 if s["ships"]==[] else 1)' && echo 0 || echo 1)" \
    "and sees nothing of anyone else's"

status="$(get "$KEY" /history/nonsense)"
check "$([ "$status" = "404" ] && echo 0 || echo 1)" "an unknown history route is a 404 from the bridge" "got $status"

# #### The station economy #### --
#
# The store's other half: the mod reports lifetime totals, and the bridge differences
# samples of them into a rate. Nothing in the Lua tests reaches that arithmetic, and
# nothing in the PHP tests reaches it through the real transport.

echo
echo "economy"

status="$(get "$KEY" /stations)"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" "GET /stations round-trips" "got $status: $(head -c 200 "$WORK/body")"

kind="$(json 'import json,sys;b=json.load(open(sys.argv[1]));print(b["stations"][0]["economy"]["kind"] if b["stations"] else "")')"
check "$([ "$kind" = "factory" ] && echo 0 || echo 1)" \
    "the station is read out of its database row, sector unloaded" "got '$kind'"

status="$(get "$KEY" /economy)"
money="$(json 'import json,sys;print(json.load(open(sys.argv[1]))["factions"][0]["money"])')"
check "$([ -n "$money" ] && [ "$money" != "0" ] && echo 0 || echo 1)" \
    "GET /economy reports the faction ledger" "got '$money'"

# The fake server moves the station's counters every few seconds, so two samples far
# enough apart must differ. HISTORY_ECONOMY_INTERVAL is the floor between stored samples
# and defaults to 300s, which is longer than this test is prepared to wait.
"${COMPOSE[@]}" down >/dev/null 2>&1
echo "HISTORY_ECONOMY_INTERVAL=30" >> "$WORK/env"
"${COMPOSE[@]}" up -d >/dev/null 2>&1
await

get "$KEY" /stations >/dev/null
sleep 32
get "$KEY" /stations >/dev/null

status="$(get "$KEY" '/history/economy/summary')"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" "the bridge answers /history/economy/summary" "got $status"

earned="$(json 'import json,sys;b=json.load(open(sys.argv[1]));print(b["stations"][0]["earned"] if b["stations"] else -1)')"
check "$([ "${earned:-0}" -gt 0 ] && echo 0 || echo 1)" \
    "two samples of a lifetime total become an amount earned" "got '$earned'"

rate="$(json 'import json,sys;b=json.load(open(sys.argv[1]));print(1 if b["stations"] and b["stations"][0]["perHour"]["net"] != 0 else 0)')"
check "$([ "$rate" = "1" ] && echo 0 || echo 1)" "and a rate per observed hour" "got '$rate'"

status="$(get "$KEY" '/history/economy/goods')"
moved="$(json 'import json,sys;b=json.load(open(sys.argv[1]));print(1 if any(g["in"] or g["out"] for g in b["goods"]) else 0)')"
check "$([ "$moved" = "1" ] && echo 0 || echo 1)" \
    "and the stock differences say which goods moved" "got '$moved'"

status="$(get "$KEY" '/history/economy/series?bucket=day')"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" "the series buckets on request" "got $status"

status="$(get bogus '/history/economy/summary')"
stations="$(json 'import json,sys;print(len(json.load(open(sys.argv[1]))["stations"]))')"
check "$([ "$status" = "200" ] && [ "$stations" = "0" ] && echo 0 || echo 1)" \
    "an unknown key reads an empty economy, not someone else's" "got $status, $stations stations"

# #### The poller #### --
#
# The service that makes the history continuous. Nothing in the mod pushes, so without
# this the record only covers the moments something happened to be calling - which is the
# one property of the store a user is most likely to be surprised by. Worth pinning that
# it actually runs on its own.

echo
echo "poller"

# It starts with POLL_KEYS empty, so up to here it has said so and exited. Give it the key
# the fake server issued and bring it back.
echo "POLL_KEYS=$KEY" >> "$WORK/env"
"${COMPOSE[@]}" up -d poller >/dev/null 2>&1

curl -s -m 40 -X POST -o /dev/null -H "X-API-Key: $KEY" \
    "http://127.0.0.1:$PORT/history/clear" 2>/dev/null

status="$(get "$KEY" /history/summary)"
empty="$(json 'import json,sys;print(len(json.load(open(sys.argv[1]))["ships"]))')"
check "$([ "$empty" = "0" ] && echo 0 || echo 1)" "the history starts cleared" "got $empty"

# Nothing below calls /ships. If craft show up in the history it is because the poller put
# them there - which is the whole point of the service.
for _ in $(seq 1 40); do
    get "$KEY" /history/summary >/dev/null
    seen="$(json 'import json,sys;print(len(json.load(open(sys.argv[1]))["ships"]))')"
    [ "${seen:-0}" -gt 0 ] && break
    sleep 1
done

check "$([ "${seen:-0}" -gt 0 ] && echo 0 || echo 1)" \
    "it records the fleet with nothing else calling the API" "saw ${seen:-0} craft"

# The stations' own trade and production feed is the one collection that is not a snapshot:
# it lives in a ring buffer in the mod, and only the poller paging through it keeps it.
for _ in $(seq 1 40); do
    get "$KEY" /history/economy/observed >/dev/null
    traded="$(json 'import json,sys;b=json.load(open(sys.argv[1]));print(sum(s["trades"] for s in b["stations"]))')"
    [ "${traded:-0}" -gt 0 ] && break
    sleep 1
done

check "$([ "${traded:-0}" -gt 0 ] && echo 0 || echo 1)" \
    "it collects the stations' trade feed on its own" "saw ${traded:-0} trades"

utilization="$(json 'import json,sys;b=json.load(open(sys.argv[1]));p=b["stations"][0]["production"] if b["stations"] else None;print(p["utilization"] if p else "")')"
check "$([ "$utilization" = "0.6667" ] && echo 0 || echo 1)" \
    "and the production windows become a measured utilisation" "got '$utilization'"

logs="$("${COMPOSE[@]}" logs poller 2>&1 | tail -20)"
check "$(echo "$logs" | grep -q 'polling 1 key' && echo 0 || echo 1)" \
    "and says what it is polling on startup" "$(echo "$logs" | tail -3)"

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
