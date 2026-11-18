#!/usr/bin/env bash
# Runs after the site data is built. Lists the generated files so the page requests only
# what exists, and refuses to publish test fixtures.
set -euo pipefail

data_dir="site/data"
mkdir -p "$data_dir"

if grep -rl --include='*.json' '"mock_fixture"' site; then
    echo "Test fixtures found under site/, refusing to deploy" >&2
    exit 1
fi

files="$(find "$data_dir" -type f ! -name files.json -printf '"%P"\n' | LC_ALL=C sort | paste -sd, -)"
printf '{"files":[%s]}\n' "$files" > "$data_dir/files.json"
