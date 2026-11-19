#!/usr/bin/env bash
# Prints the CPUs that one part of the site build is pinned to, as a list for `taskset -c`, or nothing
# when the machine is too small to give each part its own cores.
#
#   cpu_set.sh benchmarks|scenarios|calibration
#
# The three parts run at the same time on runners of one machine. Each gets whole physical cores, with
# their hyperthread siblings, counted from the highest-numbered core, and no two parts share a core. The
# benchmark part's timed solves then never compete with the worker pools of the other two parts for a
# core. Processes outside this build are not restricted, so the benchmark output still records the host
# load.
set -euo pipefail

part="${1:?usage: cpu_set.sh benchmarks|scenarios|calibration}"
# Physical cores for each part: the benchmark process alone; scenarios and calibration one per worker
# (SITE_WORKERS in the workflow) plus one for the coordinating process.
case "$part" in
    benchmarks) offset=0; count=2 ;;
    scenarios) offset=2; count=5 ;;
    calibration) offset=7; count=9 ;;
    *) echo "unknown part $part" >&2; exit 1 ;;
esac
needed=32

mapfile -t cores < <(cat /sys/devices/system/cpu/cpu[0-9]*/topology/thread_siblings_list 2>/dev/null |
    sort -u | sort -t, -k1,1nr)
[ "${#cores[@]}" -ge "$needed" ] || exit 0
printf '%s\n' "${cores[@]:offset:count}" | paste -sd, -
