#!/usr/bin/env bash
# Copy the mod into the game's mods directory, in the shape the Workshop uploader expects.
#
# Avorion publishes whatever sits in <mods>/<name>/, so what lands there is exactly what
# subscribers get. Only the mod itself belongs in it: data/ is what the game loads, docs/
# and the loose files are what the Workshop page and the README link to, and tests/ is
# small, self-contained and worth reading beside the code. Everything else in this repo is
# development scaffolding - .git/, tools/, the Docker stack, the web console, the local
# galaxy - and is left behind rather than shipped.
#
#   tools/copy.sh [destination]
#
# Destination defaults to $AVORION_MOD_DIR, then ~/.avorion/mods/<name>.
set -euo pipefail

cd "$(dirname "$0")/.."

command -v git >/dev/null || { echo "copy.sh needs git to decide what ships" >&2; exit 1; }

# modinfo.lua is the source of truth for both of these (see tools/bump.sh), so a rename or
# a bump is followed here rather than repeated.
name=$(sed -n 's/^ *name = "\([^"]*\)",$/\1/p' modinfo.lua)
version=$(sed -n 's/^ *version = "\([^"]*\)",$/\1/p' modinfo.lua)
[ -n "$name" ] && [ -n "$version" ] || { echo "cannot read name/version from modinfo.lua" >&2; exit 1; }

dest="${1:-${AVORION_MOD_DIR:-$HOME/.avorion/mods/$name}}"

# What ships, listed through git: the working tree's content, but only the files git knows
# about, so a scratch file left in data/ or a log dropped in docs/ cannot reach the
# Workshop. The second list is the loose files - no slash is top level, no leading dot
# keeps .gitignore and .env out.
mapfile -t files < <(git ls-files -- data docs tests; git ls-files | grep -vE '/|^\.')
[ "${#files[@]}" -gt 0 ] || { echo "nothing to copy - is this the repo root?" >&2; exit 1; }

# An rm -rf driven by an argument or the environment deserves a look first. A previous copy
# identifies itself by its modinfo.lua; anything else - a typo, a half-right path, a
# directory that is someone's actual work - is refused instead of emptied.
if [ -e "$dest" ]; then
    [ -d "$dest" ] || { echo "not a directory: $dest" >&2; exit 1; }
    if [ -n "$(ls -A "$dest")" ] && ! grep -q "name = \"$name\"" "$dest/modinfo.lua" 2>/dev/null; then
        echo "refusing to empty $dest" >&2
        echo "  it is not empty and holds no modinfo.lua naming $name" >&2
        exit 1
    fi
    find "$dest" -mindepth 1 -delete
else
    mkdir -p "$dest"
fi

# --parents rebuilds data/scripts/lib/... under the destination, so no directory list has to
# be kept in step with the tree.
cp --parents -t "$dest" -- "${files[@]}"

echo "$name v$version -> $dest"
echo "  ${#files[@]} files"

# Copying the working tree is deliberate - it is how a change gets into the game without a
# commit first - but the Workshop keeps whatever was uploaded, so say when the two differ.
# Asked about the copied files only, and untracked ones are not among them, so the note
# means what it says rather than firing over a scratch file that stayed behind.
if [ -n "$(git status --porcelain --untracked-files=no -- "${files[@]}")" ]; then
    echo "  note: uncommitted changes are included in this copy"
fi
