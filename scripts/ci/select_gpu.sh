#!/usr/bin/env bash
# Chooses a GPU for one build job and exports it to later steps. Indices follow PCI order, as
# nvidia-smi reports them. GPUs in GPU_EXCLUDE are never chosen.
#
#   select_gpu.sh exclusive   a GPU that no other build job holds (the benchmark job)
#   select_gpu.sh shared      a GPU that may be shared with other shared jobs, never with an
#                             exclusive one while another GPU is available
#   select_gpu.sh release     drop this job's claim (run at the end of the job, also on failure)
#
# Several runners on one machine run jobs at the same moment, and a job does not allocate GPU memory
# until well after it has chosen, so memory in use alone cannot keep two jobs apart. Each choice is
# made under a lock and recorded as a claim in a file shared by the runners. Claims are removed by
# `release` and expire after GPU_CLAIM_TTL_S seconds, so a job that was killed does not hold a GPU.
#
# Choice:
#   exclusive  the eligible GPU with no live claim and the least memory in use. If every eligible GPU
#              is claimed, wait up to GPU_WAIT_S seconds for one to be released, then take the GPU with
#              the fewest claims and warn. The benchmark output records other processes on the GPU.
#   shared     among eligible GPUs without an exclusive claim, one that shared jobs already hold, else
#              the one with the least memory in use. With none, the GPU with the fewest claims.
set -euo pipefail

mode="${1:?usage: select_gpu.sh exclusive|shared|release}"
# /tmp rather than TMPDIR or RUNNER_TEMP, which can differ between runners on one machine.
lock_dir="${GPU_LOCK_DIR:-/tmp}/campus-steam-exa-gpu"
claims="$lock_dir/claims"
ttl="${GPU_CLAIM_TTL_S:-5400}"
wait_s="${GPU_WAIT_S:-300}"
# One claim per job of a workflow run. Outside GitHub Actions, one per shell.
claim_id="${GPU_CLAIM_ID:-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-job}-${GPU_PART:-$$}}"

mkdir -p "$lock_dir"
touch "$claims"

# Runs "$@" while holding the lock.
locked() {
    (
        flock -w 120 9 || { echo "::error::Could not take the GPU lock"; exit 1; }
        "$@"
    ) 9>"$lock_dir/lock"
}

# Rewrites the claim file without expired claims and without claims matching $1 (if given).
prune() {
    local drop="${1:-}" now tmp
    now="$(date +%s)"
    tmp="$(mktemp "$lock_dir/claims.XXXXXX")"
    awk -v now="$now" -v ttl="$ttl" -v drop="$drop" \
        'NF == 4 && now - $4 < ttl && $3 != drop' "$claims" > "$tmp" || true
    mv "$tmp" "$claims"
}

release() {
    prune "$claim_id"
    echo "Released GPU claim"
}

# Prints "index used_mib exclusive_claims shared_claims" for each eligible GPU.
gpu_table() {
    local exclude=",${GPU_EXCLUDE:-},"
    nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits |
        while IFS=', ' read -r index used; do
            case "$exclude" in *",$index,"*) continue ;; esac
            ex="$(awk -v g="$index" '$1 == g && $2 == "exclusive"' "$claims" | wc -l)"
            sh="$(awk -v g="$index" '$1 == g && $2 == "shared"' "$claims" | wc -l)"
            echo "$index $used $ex $sh"
        done
}

# Chooses under the lock and records the claim. Prints the chosen index, or nothing when an
# exclusive job should wait. $1 = mode, $2 = 1 to accept any GPU.
choose() {
    local role="$1" force="$2" table pick
    prune "$claim_id"
    table="$(gpu_table)"
    [ -n "$table" ] || return 0
    if [ "$role" = exclusive ]; then
        pick="$(awk '$3 + $4 == 0' <<<"$table" | sort -k2,2n -k1,1n | head -n1)"
        [ -z "$pick" ] && [ "$force" = 1 ] && pick="$(sort -k3,3n -k4,4n -k2,2n -k1,1n <<<"$table" | head -n1)"
    else
        pick="$(awk '$3 == 0 && $4 > 0' <<<"$table" | sort -k2,2n -k1,1n | head -n1)"
        [ -z "$pick" ] && pick="$(awk '$3 == 0' <<<"$table" | sort -k2,2n -k1,1n | head -n1)"
        [ -z "$pick" ] && pick="$(sort -k3,3n -k4,4n -k2,2n -k1,1n <<<"$table" | head -n1)"
    fi
    [ -n "$pick" ] || return 0
    set -- $pick
    echo "$1 $role $claim_id $(date +%s)" >> "$claims"
    echo "$1 $2 $3 $4"
}

case "$mode" in
    release) locked release; exit 0 ;;
    exclusive|shared) ;;
    *) echo "::error::Unknown mode $mode"; exit 1 ;;
esac

if [ -z "$(gpu_table)" ]; then
    echo "::error::No eligible GPU found"
    exit 1
fi

deadline=$(( $(date +%s) + wait_s ))
result=""
while :; do
    force=0
    [ "$(date +%s)" -ge "$deadline" ] && force=1
    result="$(locked choose "$mode" "$force")"
    [ -n "$result" ] && break
    [ "$mode" = exclusive ] && echo "Every eligible GPU is held by another build job, waiting"
    sleep 15
done

read -r selected used ex sh <<<"$result"
if [ "$mode" = exclusive ] && [ $((ex + sh)) -gt 0 ]; then
    echo "::warning::No GPU was free of other build jobs after ${wait_s} s; GPU $selected is shared"
fi
echo "Selected GPU index $selected, $mode (${used} MiB in use, held by $((ex + sh)) other build jobs)"
if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "CUDA_DEVICE_ORDER=PCI_BUS_ID"
        echo "CUDA_VISIBLE_DEVICES=$selected"
        echo "GPU_CLAIM_ID=$claim_id"
    } >> "$GITHUB_ENV"
else
    echo "CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=$selected GPU_CLAIM_ID=$claim_id"
fi
