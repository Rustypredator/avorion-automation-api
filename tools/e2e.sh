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

post() {
    curl -s -m 40 -o "$WORK/body" -w '%{http_code}' -X POST \
        -H "X-API-Key: $1" -H 'Content-Type: application/json' \
        -d "$3" "http://127.0.0.1:$PORT$2"
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
MEMBER_KEY="$(grep -o 'avo_[a-f0-9]*' "$WORK/fake.log" | sed -n 2p)"
check "$([ -n "$KEY" ] && [ -n "$MEMBER_KEY" ] && echo 0 || echo 1)" "the fake server came up and issued two keys"

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

# #### Alliance history #### --
#
# Rows belong to the craft's owner, and the bridge asks the mod - by relaying a /ping of its
# own - which alliance a key's player is in before it lets that key read alliance rows. So
# this goes through the real transport or it proves nothing.

echo
echo "alliance history"

status="$(get "$KEY" '/ships?owner=all')"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" "GET /ships?owner=all round-trips" "got $status"

status="$(get "$MEMBER_KEY" /history/summary)"
names="$(json 'import json,sys;print(",".join(sorted(s["name"] for s in json.load(open(sys.argv[1]))["ships"])))')"
check "$([ "$names" = "Alliance Hauler" ] && echo 0 || echo 1)" \
    "another member reads the alliance craft the first one recorded, and none of theirs" "got '$names'"
alliance="$(json 'import json,sys;print((json.load(open(sys.argv[1]))["scope"]["alliance"] or {}).get("name",""))')"
check "$([ "$alliance" = "Test Alliance" ] && echo 0 || echo 1)" \
    "having had the membership confirmed by the mod" "got '$alliance'"

status="$(get "$KEY" /history/summary)"
names="$(json 'import json,sys;print(",".join(sorted(s["name"] for s in json.load(open(sys.argv[1]))["ships"])))')"
check "$([ "$names" = "Alliance Hauler,Ore Hound,Tug" ] && echo 0 || echo 1)" \
    "while the recording member reads both their own craft and the alliance's" "got '$names'"

status="$(curl -s -m 40 -X POST -o "$WORK/body" -w '%{http_code}' -H "X-API-Key: $MEMBER_KEY" \
    "http://127.0.0.1:$PORT/history/clear?owner=alliance")"
check "$([ "$status" = "403" ] && echo 0 || echo 1)" "no single member can clear the alliance's history" "got $status"

# The goods search's head start: a hold read once is there for every member.
get "$KEY" /ships/Ore%20Hound >/dev/null
status="$(get "$KEY" /history/manifests)"
held="$(json 'import json,sys;print(",".join(m["ship"] for m in json.load(open(sys.argv[1]))["manifests"]))')"
check "$([ "$held" = "Ore Hound" ] && echo 0 || echo 1)" "reading a craft keeps its manifest" "got '$held'"
get "$MEMBER_KEY" /history/manifests >/dev/null
held="$(json 'import json,sys;print(len(json.load(open(sys.argv[1]))["manifests"]))')"
check "$([ "$held" = "0" ] && echo 0 || echo 1)" "and a personal craft's stays private" "got '$held'"

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

# #### Keys #### --
#
# A player managing their own keys over the API, which is what the console's Keys tab
# drives. The interesting half is the last check: a revoke has to actually take the key
# out of the mod's hands, not merely out of a listing.

echo
echo "keys"

FP="$(printf %s "$KEY" | cut -c5-12)"
MEMBER_FP="$(printf %s "$MEMBER_KEY" | cut -c5-12)"

mine='import json,sys;b=json.load(open(sys.argv[1]));k=[e for e in b["keys"] if e["fingerprint"]==sys.argv[2]];print(json.dumps(k[0]) if k else "")'

status="$(get "$KEY" /keys)"
listed="$(python3 -c "$mine" "$WORK/body" "$FP")"
leaked="$(grep -c "$KEY" "$WORK/body" 2>/dev/null || true)"
check "$([ "$status" = "200" ] && [ -n "$listed" ] && echo 0 || echo 1)" \
    "a player reads their own keys by fingerprint" "got $status: $listed"
check "$([ "$leaked" = "0" ] && echo 0 || echo 1)" \
    "and the listing carries no key itself" "found it $leaked time(s)"
check "$(echo "$listed" | grep -q '"current": *true' && echo 0 || echo 1)" \
    "the key the request came with is marked as this one" "got $listed"

status="$(post "$KEY" "/keys/$FP" '{"label":"e2e console"}')"
named="$(python3 -c "$mine" "$WORK/body" "$FP")"
check "$([ "$status" = "200" ] && echo "$named" | grep -q 'e2e console' && echo 0 || echo 1)" \
    "a key can be renamed through the bridge" "got $status: $named"

# Another player's key is not theirs to touch, and the answer must not even admit it
# exists: the same 404 as a fingerprint nobody was ever issued.
status="$(post "$MEMBER_KEY" "/keys/$FP" '{"label":"mine now"}')"
check "$([ "$status" = "404" ] && echo 0 || echo 1)" \
    "and not by anybody else" "got $status: $(code)"

status="$(post "$MEMBER_KEY" "/keys/$MEMBER_FP/delete" '{}')"
gone="$(json 'import json,sys;b=json.load(open(sys.argv[1]));print(1 if b.get("wasCurrent") and not b["keys"] else 0)')"
check "$([ "$status" = "200" ] && [ "$gone" = "1" ] && echo 0 || echo 1)" \
    "a player revokes their own key, and is told it was the one they were holding" \
    "got $status, $gone"

status="$(get "$MEMBER_KEY" /keys)"
check "$([ "$status" = "401" ] && echo 0 || echo 1)" \
    "after which the mod itself no longer answers it" "got $status: $(code)"

# #### Enrolment #### --
#
# Which keys the background services may call the API with. Nothing is listed in .env any
# more, so this is the step that makes the two sections below do anything at all - and it
# is the one place the stack stores a credential, so it is worth proving against a real
# database and a real secret rather than only in tests/test_enrolment.php.

echo
echo "enrolment"

status="$(get "$KEY" /services)"
enrolled="$(json 'import json,sys;print(len(json.load(open(sys.argv[1]))["enrolled"]))')"
check "$([ "$status" = "200" ] && [ "$enrolled" = "0" ] && echo 0 || echo 1)" \
    "a fresh stack has nobody enrolled" "got $status, $enrolled enrolled"

# No key in the body: the bridge takes the one off the header, which is how the console
# enrols the key it is already connected with.
status="$(post "$KEY" /services/enrol '{"poll":true,"notify":false,"label":"e2e"}')"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" \
    "a player enrols their own key through the bridge" "got $status: $(code)"

status="$(get "$KEY" /services)"
leaked="$(grep -c "$KEY" "$WORK/body" 2>/dev/null || true)"
services="$(json 'import json,sys;e=json.load(open(sys.argv[1]))["enrolled"];print(",".join(sorted(k for k in ("poll","notify") if e[0][k])))')"
check "$([ "$leaked" = "0" ] && echo 0 || echo 1)" \
    "and reading it back never carries the key" "found it $leaked time(s)"
check "$([ "$services" = "poll" ] && echo 0 || echo 1)" \
    "only for the service it was enrolled for" "got '$services'"

status="$(post none /services/enrol '{"poll":true}')"
check "$([ "$status" = "401" ] && echo 0 || echo 1)" \
    "a key the mod does not know enrols nothing" "got $status: $(code)"

status="$(post "$KEY" /services/enrol '{"key":"avo_not_a_real_key","poll":true}')"
check "$([ "$status" = "400" ] && echo 0 || echo 1)" \
    "nor does a key it will not vouch for, offered in the body" "got $status: $(code)"

# #### The poller #### --
#
# The service that makes the history continuous. Nothing in the mod pushes, so without
# this the record only covers the moments something happened to be calling - which is the
# one property of the store a user is most likely to be surprised by. Worth pinning that
# it actually runs on its own.
#
# It has been running since the stack came up, idling because nothing was enrolled. The
# enrolment above is what starts it working, within one POLL_INTERVAL and with nothing
# restarted - which is the point of taking the list out of .env.

echo
echo "poller"

curl -s -m 40 -X POST -o /dev/null -H "X-API-Key: $KEY" \
    "http://127.0.0.1:$PORT/history/clear" 2>/dev/null

# Clearing takes the player's own craft only; the alliance's history is everyone's.
own='import json,sys;print(len([s for s in json.load(open(sys.argv[1]))["ships"] if s["owner"]=="player"]))'

status="$(get "$KEY" /history/summary)"
empty="$(json "$own")"
check "$([ "$empty" = "0" ] && echo 0 || echo 1)" "the history starts cleared" "got $empty"

# Nothing below calls /ships. If craft show up in the history it is because the poller put
# them there - which is the whole point of the service.
for _ in $(seq 1 40); do
    get "$KEY" /history/summary >/dev/null
    seen="$(json "$own")"
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

logs="$("${COMPOSE[@]}" logs poller 2>&1 | tail -30)"
check "$(echo "$logs" | grep -q '1 key enrolled' && echo 0 || echo 1)" \
    "and noticed the enrolment without being restarted" "$(echo "$logs" | tail -3)"

# #### Notifications #### --
#
# The bridge's own, like the history: rules over what the poller recorded, pushed out over
# HTTP. Delivery and the rule engine are covered against a real database and a real web
# server by tests/test_notifications.php; what only a stack can prove is that the service
# comes up with the compose wiring it was given, and that the endpoints are served.

echo
echo "notifications"

status="$(post "$KEY" /notifications/channels \
    '{"name":"Sink","kind":"webhook","url":"http://127.0.0.1:9/nowhere"}')"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" \
    "a channel is saved through the bridge" "got $status: $(code)"

status="$(post "$KEY" /notifications/rules \
    '{"name":"Hurt","kind":"hull","config":{"below":0.4},"quiet":0}')"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" \
    "and a rule over it" "got $status: $(code)"

status="$(post "$KEY" /notifications/channels \
    '{"name":"Bad","kind":"ntfy","url":"https://ntfy.sh"}')"
check "$([ "$status" = "400" ] && echo 0 || echo 1)" \
    "a channel the bridge cannot use is refused where it is made" "got $status: $(code)"

status="$(get "$KEY" /notifications)"
token="$(json 'import json,sys;b=json.load(open(sys.argv[1]));print(b["channels"][0].get("token","-"))')"
check "$([ "$status" = "200" ] && [ "$token" = "-" ] && echo 0 || echo 1)" \
    "the summary reads back without ever carrying a channel token" "got $status, token '$token'"

status="$(get none /notifications)"
check "$([ "$status" = "401" ] && echo 0 || echo 1)" \
    "and a key the mod does not know configures nothing" "got $status: $(code)"

# Alerts are their own opt-in: enrolling to have a fleet recorded does not sign anybody
# up to be messaged about it. This is the second half of the same enrolment.
status="$(post "$KEY" /services/update "{\"id\":\"$(printf %s "$KEY" | sha256sum | cut -d' ' -f1)\",\"notify\":true}")"
check "$([ "$status" = "200" ] && echo 0 || echo 1)" \
    "alerts are switched on separately from the recording" "got $status: $(code)"

for _ in $(seq 1 30); do
    logs="$("${COMPOSE[@]}" logs notifier 2>&1 | tail -30)"
    echo "$logs" | grep -q '1 key enrolled for alerts' && break
    sleep 1
done

check "$(echo "$logs" | grep -q '1 key enrolled for alerts' && echo 0 || echo 1)" \
    "and the notifier picks that up on its own" "$(echo "$logs" | tail -3)"

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
