#!/bin/bash
# Throughput: run N copies of the benchmark side by side, each with T threads, and record the
# total wall time in throughput.csv (runs per hour = N / wall hours).
#
# Usage: run_throughput.sh ILANDC PROJECT_DIR TAG YEARS N_RUNS THREADS_PER_RUN [key=value ...]
#
# Extra key=value settings are passed to every run. Results go to throughput.csv next to this
# script, or to $THROUGHPUT_CSV if set.
#
# Each copy is a normal run_benchmark.sh run (seeds 1..N), so its own timings also land in
# results.csv. On a GPU build all copies share the GPU.
set -euo pipefail
exe=$1; project=$2; tag=$3; years=$4; n=$5; threads=$6
shift 6
here=$(cd "$(dirname "$0")" && pwd)
start=$(date +%s.%N)
for i in $(seq 1 "$n"); do
    "${here}/run_benchmark.sh" "$exe" "$project" "${tag}_x${n}" "$years" "$threads" "$i" "$@" > /dev/null &
done
wait
end=$(date +%s.%N)
python3 - "$tag" "$years" "$n" "$threads" "$start" "$end" "${THROUGHPUT_CSV:-${here}/throughput.csv}" <<'EOF'
import csv, datetime, os, sys
tag, years, n, threads, start, end, path = sys.argv[1:8]
wall = float(end) - float(start)
row = {"tag": tag, "years": years, "concurrent_runs": n, "threads_per_run": threads,
       "wall_s": round(wall, 1), "runs_per_hour": round(int(n) * 3600 / wall, 1),
       "date": datetime.date.today().isoformat()}
new = not os.path.exists(path)
with open(path, "a", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(row))
    if new:
        w.writeheader()
    w.writerow(row)
print(row)
EOF
