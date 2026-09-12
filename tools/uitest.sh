#!/usr/bin/env bash
#
# Runs tests/test_console.js against a headless DOM.
#
# web/ deliberately has no build step, no package.json and no dependencies - it is three
# files a browser loads directly. Testing it needs a DOM, though, and jsdom is not
# something to make every clone of this repo install. So the dependency lives here: a node
# image, a temporary install, and nothing left on the host.
#
#   tools/uitest.sh
#
# Needs docker. To run it without, install jsdom somewhere and point NODE_PATH at that
# node_modules:
#
#   npm install jsdom && NODE_PATH=node_modules node tests/test_console.js

set -uo pipefail

cd "$(dirname "$0")/.."

IMAGE="node:22-alpine"
JSDOM_VERSION="${JSDOM_VERSION:-26}"

# npm writes into $HOME, which is / for a container running as an arbitrary uid, so it is
# pointed at the writable scratch directory instead. The repo is mounted read-only: this
# test reads web/ and tests/ and must not be able to touch either.
docker run --rm \
    -v "$PWD:/repo:ro" \
    -w /work \
    -e HOME=/work \
    -e NODE_PATH=/work/node_modules \
    "$IMAGE" \
    sh -c "npm install --silent --no-audit --no-fund jsdom@${JSDOM_VERSION} >/dev/null 2>&1 \
           && cp -r /repo/web /repo/tests /work/ \
           && node /work/tests/test_console.js"
