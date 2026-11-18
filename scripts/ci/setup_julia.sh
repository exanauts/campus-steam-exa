#!/usr/bin/env bash
# Installs the pinned Julia release into the runner tool cache. Used on the
# self-hosted runner in place of setup-julia, which logs absolute install paths.
set -euo pipefail

version="1.13.3"
sha256="5c61cb4b40332cb5a3504e7779e2f5dac093caa4a1116ded19f01413f85c63e4"

[ "${CI_JULIA_VERSION:?}" = "$version" ] || { echo "::error::setup_julia.sh pins Julia $version"; exit 1; }

cache="${RUNNER_TOOL_CACHE:?}/campus-steam-exa"
target="$cache/julia-$version"
if [ -x "$target/bin/julia" ]; then
    echo "Julia $version already installed"
    exit 0
fi

mkdir -p "$cache"
work="$(mktemp -d "$cache/download.XXXXXX")"
trap 'rm -rf "$work"' EXIT
curl -fsSL --retry 3 -o "$work/julia.tar.gz" \
    "https://julialang-s3.julialang.org/bin/linux/x64/${version%.*}/julia-$version-linux-x86_64.tar.gz"
echo "$sha256  $work/julia.tar.gz" | sha256sum --check --quiet --status
tar -xzf "$work/julia.tar.gz" -C "$work"
mv "$work/julia-$version" "$target"
echo "Julia $version installed"
