# Sourced by each self-hosted workflow step. Keeps machine-specific paths out of
# the workflow environment, which the runner prints in the public job log.
set -euo pipefail

CAMPUS_STEAM_CACHE="${RUNNER_TOOL_CACHE:?}/campus-steam-exa"
export JULIA_DEPOT_PATH="$CAMPUS_STEAM_CACHE/depot"
export PATH="$CAMPUS_STEAM_CACHE/julia-$CI_JULIA_VERSION/bin:$PATH"
export JULIA_PKG_PRECOMPILE_AUTO=1

# Replaces machine-specific strings in everything a step prints.
scrub() {
    local host short args=()
    host="$(hostname -f 2>/dev/null || hostname)"
    short="$(hostname -s)"
    local pair
    for pair in \
        "$CAMPUS_STEAM_CACHE=<cache>" \
        "${GITHUB_WORKSPACE:-}=<workspace>" \
        "${RUNNER_WORKSPACE:-}=<runner-workspace>" \
        "${RUNNER_TEMP:-}=<runner-temp>" \
        "${RUNNER_TOOL_CACHE:-}=<tool-cache>" \
        "${HOME:-}=<home>" \
        "$host=<host>" \
        "$short=<host>" \
        "${USER:-$(id -un)}=<user>"; do
        local from="${pair%%=*}" to="${pair#*=}"
        [ -n "$from" ] || continue
        from="$(printf '%s' "$from" | sed 's/[][\.*^$#]/\\&/g')"
        args+=(-e "s#$from#$to#g")
    done
    sed -u "${args[@]}"
}
