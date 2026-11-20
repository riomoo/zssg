#!/bin/sh
# ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
# Licensed under +THYME (see LICENSE).
# Conformance check: build each site in tests/sites with both Hugo and ZSSG and
# diff the output trees. Requires `hugo` (v0.170.0) on PATH.
#
#   zig build && tests/compare.sh [path/to/zssg]
set -u
ZSSG=${1:-"$(dirname "$0")/../zig-out/bin/zssg"}
ZSSG=$(cd "$(dirname "$ZSSG")" && pwd)/$(basename "$ZSSG")
command -v hugo >/dev/null 2>&1 || { echo "hugo not found on PATH"; exit 2; }
TMP=$(mktemp -d)
fail=0
for site in "$(dirname "$0")"/sites/*/; do
    name=$(basename "$site")
    hugo --quiet -s "$site" -d "$TMP/$name-hugo" >/dev/null 2>&1 || { echo "SKIP $name (hugo failed)"; continue; }
    "$ZSSG" --quiet -s "$site" -d "$TMP/$name-zssg" || { echo "FAIL $name (zssg failed)"; fail=1; continue; }
    # the generator meta tag is the one intended difference
    if diff -r "$TMP/$name-hugo" "$TMP/$name-zssg" | grep '^[<>]' | grep -v 'name="generator"' | grep -q .; then
        echo "FAIL $name"
        diff -r "$TMP/$name-hugo" "$TMP/$name-zssg" | grep -v 'name="generator"' | cut -c1-200 | head -20
        fail=1
    else
        echo "ok   $name"
    fi
done
rm -rf "$TMP" "$(dirname "$0")"/sites/*/.hugo_build.lock
exit $fail
