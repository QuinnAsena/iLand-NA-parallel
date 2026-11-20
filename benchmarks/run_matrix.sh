#!/bin/bash
# The benchmark matrix behind the README tables.
#
# Usage: run_matrix.sh BIN_DIR PROJECT_DIR [key=value ...]
#   BIN_DIR holds ilandc_upstream, ilandc_cpuopt and ilandc_gpu (see gpu/README.md)
#   key=value settings are passed to every run; the README's timing tables use
#   modules.fire.enabled=false (see there). RESULTS_CSV / THROUGHPUT_CSV choose the output files.
#
# 1. 300 years (the CPCRW spin-up) with all cores, seeds 1-3, the three builds interleaved
# 2. thread scaling, 150 years: 4, 8 and all threads for each build, plus 1 thread (CPU build)
# 3. throughput, 150 years: 4 runs x 7 threads side by side vs. 1 run x all threads
set -euo pipefail
bin=$1; project=$2
shift 2
here=$(cd "$(dirname "$0")" && pwd)
cores=$(nproc)

for seed in 1 2 3; do
    for build in upstream cpuopt gpu; do
        "${here}/run_benchmark.sh" "${bin}/ilandc_${build}" "$project" "$build" 300 -1 "$seed" "$@"
    done
done

for threads in 4 8 -1; do
    for build in upstream cpuopt gpu; do
        "${here}/run_benchmark.sh" "${bin}/ilandc_${build}" "$project" "${build}_scaling" 150 "$threads" 1 "$@"
    done
done
"${here}/run_benchmark.sh" "${bin}/ilandc_cpuopt" "$project" cpuopt_scaling 150 1 1 "$@"

for build in upstream cpuopt gpu; do
    "${here}/run_throughput.sh" "${bin}/ilandc_${build}" "$project" "$build" 150 1 "$cores" "$@"
    "${here}/run_throughput.sh" "${bin}/ilandc_${build}" "$project" "$build" 150 4 $((cores / 4)) "$@"
done
