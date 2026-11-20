#!/bin/bash
# Run one benchmark of iLand on the CPCRW-like project and append the timings to results.csv.
#
# Usage:
#   run_benchmark.sh ILANDC PROJECT_DIR TAG YEARS THREADS [SEED] [extra key=value ...]
#
#   ILANDC       path to the ilandc executable
#   PROJECT_DIR  folder made by make_cpcrw_like.py
#   TAG          label for this build/setting, e.g. upstream, rngfix, gpu
#   YEARS        simulation years (CPCRW spin-up: 300)
#   THREADS      iLand threadCount (-1 = all cores, as in the CPCRW project file)
#   SEED         random seed (default 0 = new seed every run, as in CPCRW)
#
# The model is called with the same key=value overrides as scripts/run_iland_csv_cpxml.sh
# (fire return interval 120, epsilon 2.7, sapling-detail min. dbh 2.5), and each run
# writes to its own output folder with crownkill/, nFire/ and log/, as on the HPC.
# Timings come from the wall clock and from iLand's own timers in the log file.
# Results go to results.csv next to this script, or to $RESULTS_CSV if set.

set -euo pipefail
exe=$1; project=$(cd "$2" && pwd); tag=$3; years=$4; threads=$5; seed=${6:-0}
shift 6 2>/dev/null || shift $#
extra=("$@")

here=$(cd "$(dirname "$0")" && pwd)
run_id="${tag}_y${years}_t${threads}_s${seed}_$(date +%Y%m%d%H%M%S)"
out="${project}/output/${run_id}"
mkdir -p "${out}/crownkill" "${out}/nFire" "${out}/log"
xml="${project}/${run_id}.xml"
sed "s|<output>.*</output>|<output>${out}</output>|" "${project}/CPCRW_like.xml" > "$xml"

start=$(date +%s.%N)
/usr/bin/time -f "%M" -o "${out}/maxrss_kb.txt" "$exe" "$xml" "$years" \
    system.database.out="${run_id}.sqlite" \
    system.logging.logFile="${out}/log/log.txt" \
    system.settings.threadCount="$threads" \
    system.settings.randomSeed="$seed" \
    modules.fire.fireReturnInterval=120 \
    model.settings.epsilon=2.7 \
    output.saplingdetail.minDbh=2.5 \
    "${extra[@]}" > "${out}/stdout.txt" 2>&1
end=$(date +%s.%N)
rm -f "$xml"

python3 - "$out" "$tag" "$exe" "$years" "$threads" "$seed" "$start" "$end" "${RESULTS_CSV:-${here}/results.csv}" "${extra[*]:-}" <<'EOF'
import csv, os, platform, re, sys, datetime
out, tag, exe, years, threads, seed, start, end, results, extra = sys.argv[1:11]
log = open(os.path.join(out, "log", "log.txt"), errors="replace").read()

def seconds(name):
    # iLand prints cumulative timers as "name" : "1m 2.5s" / "12.3s" / "450ms"
    m = re.findall(r'"%s" : "([^"]+)"' % re.escape(name), log)
    if not m:
        return ""
    total = 0.0
    for part in m[-1].split():
        if part.endswith("ms"): total += float(part[:-2]) / 1000
        elif part.endswith("s"): total += float(part[:-1])
        elif part.endswith("m"): total += 60 * float(part[:-1])
        elif part.endswith("h"): total += 3600 * float(part[:-1])
    return round(total, 3)

failed = "!!!! ERROR" in log or "model run finished" not in log
row = {
    "tag": tag, "years": years, "threads": threads, "seed": seed,
    "wall_s": round(float(end) - float(start), 2),
    "model_s": seconds("Model::runYear()"),
    "light_apply_s": seconds("applyPattern()"), "light_read_s": seconds("readPattern()"),
    "tree_growth_s": seconds("growTrees()"), "production_s": seconds("growRU()"),
    "seed_dispersal_s": seconds("seed dispersal (all species)"),
    "establishment_s": seconds("establishment"), "sapling_growth_s": seconds("sapling growth"),
    "outputs_s": seconds("outputs"), "management_s": seconds("management"),
    "fire_s": seconds("modules"),
    "max_rss_mb": round(int(open(os.path.join(out, "maxrss_kb.txt")).read().split()[-1]) / 1024),
    "status": "failed" if failed else "ok",
    "extra": extra, "executable": os.path.basename(exe),
    "cpu": next((l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name")), platform.processor()),
    "cores": os.cpu_count(), "date": datetime.date.today().isoformat(),
}
new = not os.path.exists(results)
with open(results, "a", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(row))
    if new:
        w.writeheader()
    w.writerow(row)
print(f"{tag} years={years} threads={threads} seed={seed}: wall {row['wall_s']} s, model {row['model_s']} s, "
      f"establishment {row['establishment_s']} s, light {row['light_apply_s']}+{row['light_read_s']} s, "
      f"seed dispersal {row['seed_dispersal_s']} s [{row['status']}]")
EOF
