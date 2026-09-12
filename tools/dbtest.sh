#!/usr/bin/env bash
#
# Runs tests/test_history.php against a throwaway Postgres.
#
# The history store is the one piece of real logic on the bridge side of the transport -
# nothing in the Lua tests covers it - and it is SQL, so it cannot be tested against a
# stub. This starts a database, runs the test in the same image the bridge is built from,
# and takes both down again.
#
#   tools/dbtest.sh
#
# Needs docker. Leaves nothing behind, including on failure.

set -uo pipefail

cd "$(dirname "$0")/.."

TAG="avo-dbtest-$$"
PASSWORD="$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')"

cleanup() {
    docker rm -f "$TAG" >/dev/null 2>&1
    docker network rm "$TAG" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

docker network create "$TAG" >/dev/null || exit 1

echo "starting a throwaway postgres"
docker run -d --name "$TAG" --network "$TAG" \
    -e POSTGRES_DB=avorion \
    -e POSTGRES_USER=avorion \
    -e POSTGRES_PASSWORD="$PASSWORD" \
    postgres:16-alpine >/dev/null || exit 1

# pg_isready rather than a fixed sleep: the process accepts connections a second or two
# after the container appears, and how long varies with how busy the machine is.
for _ in $(seq 1 60); do
    if docker exec "$TAG" pg_isready -U avorion -d avorion >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done

if [ -z "${ready:-}" ]; then
    echo "  FAIL the database never came up"
    docker logs "$TAG" 2>&1 | tail -20
    exit 1
fi

# pdo_pgsql is not in the stock FrankenPHP image, so this uses the bridge's own, which
# adds it. Building it here also means a Dockerfile that cannot build fails this test
# rather than only failing a deployment.
echo "building the bridge image"
docker build -q -t "$TAG-php" ./docker/bridge >/dev/null || exit 1

docker run --rm --network "$TAG" \
    -v "$PWD:/w:ro" -w /w \
    -e HISTORY_DB_HOST="$TAG" \
    -e HISTORY_DB_NAME=avorion \
    -e HISTORY_DB_USER=avorion \
    -e HISTORY_DB_PASSWORD="$PASSWORD" \
    --entrypoint php \
    "$TAG-php" tests/test_history.php
status=$?

docker rmi "$TAG-php" >/dev/null 2>&1

exit $status
