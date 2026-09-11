#!/usr/bin/env bash
# Set the mod version everywhere it appears.
#
# modinfo.lua is the source of truth - the Workshop reads it, and the game parses it on its
# own before any script runs, so nothing the mod loads can generate it. The rest are copies
# that have to agree; tests/test_version.lua fails if they ever stop agreeing.
#
#   tools/bump.sh 0.2.0
set -euo pipefail

new=${1:-}
if [[ ! $new =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: tools/bump.sh <major.minor.patch>" >&2
    exit 2
fi

cd "$(dirname "$0")/.."

old=$(sed -n 's/^ *version = "\([^"]*\)",$/\1/p' modinfo.lua)
echo "$old -> $new"

# Matched by shape rather than by the old value, so a file that had already drifted is
# pulled back into line instead of being skipped.
sed -i 's/^\( *version = "\)[^"]*\(",\)$/\1'"$new"'\2/'            modinfo.lua
sed -i 's/^\(Config.version = "\)[^"]*\("\)$/\1'"$new"'\2/'        data/scripts/lib/automationapi/config.lua
sed -i 's/\[!\[version [^]]*\]/[![version '"$new"']/'              README.md
sed -i 's/badge\/version-[^-]*-/badge\/version-'"$new"'-/'         README.md
sed -i 's/AutomationAPI: v[0-9][0-9.]* ready/AutomationAPI: v'"$new"' ready/' README.md docs/protocol.md
sed -i 's/"mod": "[^"]*"/"mod": "'"$new"'"/'                       docs/api.md

lua tests/test_version.lua
