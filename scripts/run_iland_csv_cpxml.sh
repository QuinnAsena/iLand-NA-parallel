#!/bin/bash
set -e # terminate if non-zero exit
set -u  # terminate if variable unset
set -o pipefail  # terminate if any command in pipeline fails

# Arguments
xml=$1
start_rep=$2
end_rep=$3

# Set variables
path="${ILAND_EXE:-/glade/work/qasena/iLand2.0/iland-model/build/ilandc/ilandc}"
output_path="/glade/derecho/scratch/qasena/output_auto/CPCRW_hist_spinup"
xml_path="/glade/work/qasena/iLand_automated"
simulation_years="300"
csv_name="/glade/work/qasena/iLand_automated/iland_reps.csv"

# Optional settings (environment variables); without them the script runs as before:
#   ILAND_EXE       iLand executable, e.g. the GPU build from gpu/build_iland.sh
#   ILAND_THREADS   threads per run (system.settings.threadCount); default: the project file (-1 = all cores)
#   ILAND_PARALLEL  number of replicates run at the same time (default 1 = one after another).
#                   iLand does not use many cores well, so several runs with fewer threads each
#                   finish more replicates per hour, e.g. ILAND_PARALLEL=4 ILAND_THREADS=16 on a
#                   64-core node (see the Performance section of the README).
#   ILAND_GPUS      number of GPUs on the node; replicate i then uses GPU (i mod ILAND_GPUS).
#                   The GPU build uses a GPU automatically if it finds one (ILAND_GPU=0 disables).
parallel="${ILAND_PARALLEL:-1}"
threads_arg=()
if [ -n "${ILAND_THREADS:-}" ]; then
    threads_arg=("system.settings.threadCount=${ILAND_THREADS}")
fi

mkdir -p "${output_path}"

run_one() {
    local fecund=$1 gcm=$2 fri=$3 epsilon=$4 dbh=$5 id=$6 rep=$7 slot=$8
    echo "running gcm $gcm with fecund $fecund rep $rep"

    local scenario_dir="${output_path}/${gcm}_${fecund}_ep${epsilon}_dbh${dbh}_${id}/rep_${rep}"
    local tmp_xml="${xml_path}/${gcm}_${fecund}_ep${epsilon}_dbh${dbh}_${id}_${rep}.xml"

    mkdir -p "${scenario_dir}/crownkill"
    mkdir -p "${scenario_dir}/nFire"
    mkdir -p "${scenario_dir}/log"

    # Create modified XML with unique output path
    cp "$xml" "$tmp_xml"
    sed -i "s|<output>.*</output>|<output>${scenario_dir}</output>|" "$tmp_xml"

    # spread replicates over the node's GPUs, if asked to
    if [ -n "${ILAND_GPUS:-}" ]; then
        export CUDA_VISIBLE_DEVICES=$(( slot % ILAND_GPUS ))
    fi

    # Run iLand model
    "${path}" "$tmp_xml" "$simulation_years" \
        system.database.out=${gcm}_${fecund}_ep${epsilon}_dbh${dbh}_${id}_${rep}.sqlite \
        system.database.climate=${gcm}.sqlite \
        system.database.in=${fecund}.sqlite \
        system.logging.logFile=${scenario_dir}/log/log_${gcm}_${fecund}_ep${epsilon}_dbh${dbh}_${id}_${rep}.txt \
        modules.fire.fireReturnInterval=${fri} \
        model.settings.epsilon=${epsilon} \
        output.saplingdetail.minDbh=${dbh} \
        ${threads_arg[@]+"${threads_arg[@]}"}

    rm "$tmp_xml"
}

# Read CSV and loop through lines; with ILAND_PARALLEL > 1, up to that many replicates run at once
running=0
slot=0
failed=0
while IFS=, read -r fecund gcm fri epsilon dbh id
do
    for rep in $(seq "$start_rep" "$end_rep")
    do
        if [ "$parallel" -le 1 ]; then
            run_one "$fecund" "$gcm" "$fri" "$epsilon" "$dbh" "$id" "$rep" "$slot"
        else
            run_one "$fecund" "$gcm" "$fri" "$epsilon" "$dbh" "$id" "$rep" "$slot" &
            running=$((running + 1))
            if [ "$running" -ge "$parallel" ]; then
                wait -n || failed=$((failed + 1))
                running=$((running - 1))
            fi
        fi
        slot=$((slot + 1))
    done
done < <(sed 1d "$csv_name")

# wait for the last parallel runs
while [ "$running" -gt 0 ]; do
    wait -n || failed=$((failed + 1))
    running=$((running - 1))
done
if [ "$failed" -gt 0 ]; then
    echo "$failed run(s) failed"
    exit 1
fi
