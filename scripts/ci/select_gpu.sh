#!/usr/bin/env bash
# Chooses the GPU with the least memory in use, skipping GPU_EXCLUDE, and exports
# it to later steps. Indices follow PCI order, as nvidia-smi reports them.
set -euo pipefail

exclude=",${GPU_EXCLUDE:-},"
selected=""
while IFS=', ' read -r index used; do
    case "$exclude" in *",$index,"*) continue ;; esac
    selected="$index"
    selected_used="$used"
    break
done < <(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits | sort -t, -k2,2n -k1,1n)

if [ -z "$selected" ]; then
    echo "::error::No eligible GPU found"
    exit 1
fi

echo "Selected GPU index $selected (${selected_used} MiB in use)"
{
    echo "CUDA_DEVICE_ORDER=PCI_BUS_ID"
    echo "CUDA_VISIBLE_DEVICES=$selected"
} >> "$GITHUB_ENV"
