#!/usr/bin/env bash
#
# Runs a headless Avorion server on the local test galaxy, with its console on a pipe so
# commands can be sent to it from scripts - including the /run helpers in
# data/scripts/lib/automationapi/devsetup.lua.
#
#   tools/localserver.sh start          start the server, wait until the mod reports ready
#   tools/localserver.sh cmd '/save'    send one console line
#   tools/localserver.sh run 'print(1)' send /run <lua> - ONE short line: the console strips
#                                       semicolons, truncates long lines and can wedge on
#                                       what is left. Anything bigger goes in devsetup.lua.
#   tools/localserver.sh lab <step>     one boss lab step (see devsetup.lua), then its output
#   tools/localserver.sh key            create an API key for PLAYER_INDEX and print it
#   tools/localserver.sh log [lines]    tail the server output
#   tools/localserver.sh status
#   tools/localserver.sh stop           save and shut down
#
# Paths come from tools/local.env (copy tools/local.env.example). The galaxy's modconfig.lua
# has to point at this repo; start says so if it does not. See docs/local-testing.md.

set -uo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"

[ -f tools/local.env ] || {
    echo "tools/local.env is missing - cp tools/local.env.example tools/local.env and fill it in" >&2
    exit 1
}
# shellcheck source=/dev/null
. tools/local.env

GALAXY="$GALAXY_DATAPATH/$GALAXY_NAME"
STATE="$REPO/.local/server"
FIFO="$STATE/console"
LOG="$STATE/server.log"
PID="$STATE/server.pid"
HOLD="$STATE/hold.pid"

LAB_X="${LAB_X:-380}"
LAB_Y="${LAB_Y:-0}"

running() { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }

send() {
    running || { echo "the server is not running" >&2; exit 1; }
    printf '%s\n' "$1" > "$FIFO"
}

# Waits for a line matching $1 to appear in the log after byte offset $2.
await() {
    local pattern="$1" from="$2" timeout="${3:-60}"
    for _ in $(seq 1 "$timeout"); do
        tail -c +"$((from + 1))" "$LOG" 2>/dev/null | grep -qE "$pattern" && return 0
        running || return 1
        sleep 1
    done
    return 1
}

size() { stat -c %s "$LOG" 2>/dev/null || echo 0; }

# A /run line starts with nothing but "?.lua" on its path, so mod libraries - devsetup,
# auth - cannot be included until the game's lib directory is added.
LIB='package.path = package.path .. ";data/scripts/lib/?.lua" '


case "${1:-}" in
start)
    running && { echo "already running (pid $(cat "$PID"))"; exit 0; }
    [ -x "$AVORION_DIR/bin/AvorionServer" ] || { echo "no bin/AvorionServer in $AVORION_DIR" >&2; exit 1; }
    [ -d "$GALAXY" ] || { echo "no galaxy at $GALAXY" >&2; exit 1; }

    if ! grep -q "path *= *\"$REPO\"" "$GALAXY/modconfig.lua" 2>/dev/null; then
        echo "warning: $GALAXY/modconfig.lua does not load this repo; it should contain" >&2
        echo "  mods = { {path = \"$REPO\"} }" >&2
    fi

    mkdir -p "$STATE"
    rm -f "$FIFO"
    mkfifo "$FIFO"
    : > "$LOG"

    # The server reads its console from stdin and would see end-of-file the moment the
    # first `cmd` closed the pipe. Something has to hold the write end open for its life.
    # Neither may inherit this script's stdout or stderr either: whatever called start (a
    # pipe, a CI step) would otherwise wait for them to close, i.e. forever.
    sleep infinity > "$FIFO" 2>/dev/null < /dev/null &
    echo $! > "$HOLD"

    cd "$AVORION_DIR" || exit 1
    bin/AvorionServer --galaxy-name "$GALAXY_NAME" --datapath "$GALAXY_DATAPATH" \
        < "$FIFO" >> "$LOG" 2>&1 &
    echo $! > "$PID"
    cd "$REPO" || exit 1

    if await "AutomationAPI: .* ready" 0 180; then
        grep -E "AutomationAPI: .* ready" "$LOG" | tail -1
        echo "server running (pid $(cat "$PID")), log: $LOG"
    else
        echo "the mod did not report ready - last lines of $LOG:" >&2
        tail -30 "$LOG" >&2
        exit 1
    fi
    ;;
cmd)
    send "$2"
    ;;
run)
    from=$(size)
    send "/run $LIB$2"
    sleep "${WAIT:-3}"
    tail -c +"$((from + 1))" "$LOG"
    ;;
lab)
    [ -n "${2:-}" ] || { echo "usage: lab <load|setup|fighters|report|kill|pickup|loot|recall|collect|plan|state|clear|forget> [route|farm]" >&2; exit 1; }
    kind="${3:+, \"$3\"}"
    from=$(size)
    send "/run ${LIB}include(\"automationapi/devsetup\").bossLab($PLAYER_INDEX, $LAB_X, $LAB_Y, \"$2\"$kind)"
    sleep "${WAIT:-3}"
    tail -c +"$((from + 1))" "$LOG" | grep -E "bosslab|devsetup|rror|Traceback|stack" || true
    ;;
key)
    from=$(size)
    send "/run ${LIB}local key = include(\"automationapi/auth\").createKey($PLAYER_INDEX, \"localserver.sh\") print(\"localserver key: \" .. tostring(key))"
    # The console echoes the /run line itself into the log, so match the key, not the label.
    if await "localserver key: avo_" "$from" 15; then
        tail -c +"$((from + 1))" "$LOG" | sed -n 's/.*localserver key: \(avo_[A-Za-z0-9]*\).*/\1/p' | tail -1
    else
        echo "no key reported" >&2
        exit 1
    fi
    ;;
log)
    tail -n "${2:-40}" "$LOG"
    ;;
status)
    if running; then echo "running (pid $(cat "$PID"))"; else echo "not running"; fi
    ;;
stop)
    if running; then
        send "/save"
        sleep 3
        send "/stop"
        for _ in $(seq 1 60); do running || break; sleep 1; done
        # A console wedged by a malformed /run line takes no /stop; SIGINT is what Ctrl-C
        # in a terminal would send, and still shuts down properly.
        if running; then
            echo "no answer to /stop, sending SIGINT"
            kill -INT "$(cat "$PID")"
            for _ in $(seq 1 60); do running || break; sleep 1; done
        fi
        running && { echo "still running, sending SIGTERM"; kill "$(cat "$PID")"; }
    fi
    [ -f "$HOLD" ] && kill "$(cat "$HOLD")" 2>/dev/null
    rm -f "$PID" "$HOLD" "$FIFO"
    echo "stopped"
    ;;
*)
    sed -n '3,16p' "$0"
    exit 1
    ;;
esac
