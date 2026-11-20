# iLand-NA-parallel
Presentation on running iLand in parallel on an HPC

## Scripts

The `scripts/` directory contains the files used to configure and run iLand simulations in parallel on an HPC cluster:

- **`run_iland_csv_cpxml.sh`** – Bash script that reads simulation parameters from `iland_reps.csv`, copies and modifies the base XML project file for each parameter combination and replicate, runs the iLand model executable, and cleans up temporary files. Optional environment variables run several replicates at once (`ILAND_PARALLEL`), set the threads per run (`ILAND_THREADS`), choose the iLand build (`ILAND_EXE`) and spread runs over a node's GPUs (`ILAND_GPUS`); without them it runs as before. See [Performance](#performance-gpu-and-benchmarks).
- **`iland_reps.csv`** – CSV file defining the parameter combinations (species parameters, climate model, fire return interval, epsilon, DBH threshold, and scenario ID) to be iterated over by the run script.
- **`CPCRW_hist_spinup_derecho.xml`** – Base iLand project file for the CPCRW historical spinup simulations. The run script copies and modifies this file for each scenario.
- **`saveWorkflow.js`** – iLand JavaScript workflow file that handles model snapshots, screenshots, and optional deterministic disturbance events during a simulation run.

The `gpu/` directory holds patches for iLand (multithreading fixes and an optional GPU path) and a script that builds them; see [gpu/README.md](gpu/README.md). The `benchmarks/` directory holds the benchmark behind the tables below.

## Performance: GPU and benchmarks

**In short:**

- **Run several replicates side by side.** On the 28-core test machine, one 150-year run on
  all 28 cores manages 61 runs per hour with upstream iLand; four runs with 7 threads
  each manage 204. iLand doesn't use many cores well, so on a 128-core Derecho node one
  run per node wastes most of it. This needs no rebuild: `ILAND_PARALLEL` and `ILAND_THREADS`
  in the run script.
- **The patched CPU build is 1.4x faster per run** (300 years, all cores). Upstream's
  threads spend much of their time queuing for one shared random-number counter; patch `0002`
  removes that. Single-threaded runs give exactly the same output as upstream.
- **The GPU build is 2.0x faster per run.** It moves light competition and seed
  dispersal to an NVIDIA GPU (patch `0003`).
- **Combined:** four GPU-build runs side by side manage 320 runs per hour, 5.2x
  the current setup (upstream, one run at a time, all cores).
- **The patched CPU and GPU builds simulate the same forest** (within about 1%).
  Single-threaded, the CPU fixes give output identical to upstream. Multithreaded upstream
  comes out 2–6% lower and varies more between runs, probably an effect of its racy
  random-number generator (see [below](#do-the-builds-simulate-the-same-forest)).

### How to use it

1. **Build the patched iLand** (Qt 6.8 and FreeImage via [pixi](https://pixi.sh); CUDA from
   the system, e.g. `module load cuda`):

   ```bash
   pixi run --manifest-path gpu/pixi.toml gpu/build_iland.sh ~/iland-build
   # -> ~/iland-build/bin/ilandc_cpu, and ~/iland-build/bin/ilandc_gpu if nvcc is found
   ```

2. **Run replicates side by side.** Suggested starting points, untested on Derecho itself:

   ```bash
   # CPU node (128 cores): 8 replicates at a time, 16 threads each
   ILAND_EXE=~/iland-build/bin/ilandc_cpu ILAND_PARALLEL=8 ILAND_THREADS=16 \
       bash scripts/run_iland_csv_cpxml.sh CPCRW_hist_spinup_derecho.xml 1 40

   # GPU node (64 cores, 4 A100s): 8 replicates at a time, 8 threads each, 2 per GPU
   ILAND_EXE=~/iland-build/bin/ilandc_gpu ILAND_PARALLEL=8 ILAND_THREADS=8 ILAND_GPUS=4 \
       bash scripts/run_iland_csv_cpxml.sh CPCRW_hist_spinup_derecho.xml 1 40
   ```

   Memory decides how many runs fit on a node. The test landscape used about 2 GB of RAM per
   run; CPCRW is about 15 times larger, so check one run's peak memory (`/usr/bin/time -v`)
   before choosing `ILAND_PARALLEL`. On the GPU each run needs well under 2 GB, so GPU memory
   is not the limit.

### What was slow, and what changed

Profiling a 300-year CPCRW-like run on 28 threads with `perf`:

- **Establishment** took 22% of the wall time but 67% of all CPU samples. Most of that was
  threads waiting: iLand's random-number generator had one global index that every thread
  incremented, so 28 threads queued for the same cache line. Patch `0002` gives every thread
  its own generator.
- **Seed dispersal** (13%) ran one thread per species, so with 4 species it used 4 of 28 cores
  while the rest waited. It is a convolution, ideal for a GPU (patch `0003`); on the GPU it
  takes under 1 s for the whole 300 years.
- **Light competition** (8%) applies every tree's light influence pattern to a 2 m grid; the
  GPU does this with atomic updates and matches the CPU to float rounding (see
  [gpu/README.md](gpu/README.md)).
- **Tree growth, outputs** (SQLite) and the rest are branchy per-tree code or disk I/O and stay
  on the CPU. That caps what a GPU can do for iLand: about half of the remaining time is in
  parts a GPU cannot take.
- Two more thread-safety bugs turned up along the way and are fixed in `0002`: a debug counter
  written by every seed-dispersal thread, and a race in `DebugTimer` that crashed one run in
  about 45 (in year 1). Both are upstream bugs.

### Benchmark

**Test case.** The CPCRW inputs aren't public, so the benchmark uses a CPCRW-like project
built by `benchmarks/make_cpcrw_like.py`. It takes this repository's
`CPCRW_hist_spinup_derecho.xml` and `saveWorkflow.js` unchanged, with the same model
settings, permafrost, fire module, management script, outputs and command-line overrides as
`run_iland_csv_cpxml.sh`. Only the inputs are swapped for the official
[iLand demo](https://iland-model.org/downloads/example_bgd.zip):
- **Landscape and soils:** the demo's 5.5 x 7.5 km landscape (2,272 ha) and its soils.
- **Species:** the four Alaskan species from its species database (black and white spruce,
  aspen, Alaska birch).
- **Climate:** its climate shifted by -7 °C.
- **Start:** bare ground with saplings, like CPCRW.

The script's docstring lists every change. Absolute times for CPCRW (25.5 x 23.9 km) will be
longer; the shares between model parts should be similar.

**Machine.** A 28-vCPU Intel Xeon (Cascade Lake) VM with 93 GB RAM and an NVIDIA A100 80GB
PCIe. Other heavy jobs on the machine were paused during the runs.

**Builds.**
- **Upstream:** iLand at commit `4dd4e6f` (2.2), plus patch `0001`, which only affects logging.
- **CPU fixes:** plus `0002`.
- **CPU fixes + GPU:** plus `0003`.

**Fire off for timing.** The timing tables come from runs with `modules.fire.enabled=false`.
With fire on, a single large fire changes how many trees a run simulates: two runs regrew
about three times as many trees after a 2,000 ha fire. That makes run times differ more
between seeds than between builds. The runs with fire on are in `results_with_fire.csv` and
show the same pattern with more spread (table at the end).

**300 years, all 28 cores** (median of 3/3/3 seeds)

| Build | Wall time | Model time | Speed-up (wall) |
|---|---|---|---|
| Upstream iLand (CPU) | 2.7 min | 2.5 min | 1.00x |
| CPU fixes | 1.8 min | 1.7 min | 1.44x |
| CPU fixes + GPU | 1.3 min | 1.2 min | 1.98x |

**Where the model time goes** (seconds, same runs)

| Part | Upstream iLand (CPU) | CPU fixes | CPU fixes + GPU |
|---|---|---|---|
| Establishment | 48.5 | 10.1 | 9.9 |
| Seed dispersal | 29.6 | 20.5 | 0.9 |
| Light: apply | 11.5 | 13.0 | 8.1 |
| Light: read | 1.0 | 1.2 | 0.6 |
| Tree growth | 17.4 | 14.0 | 9.3 |
| Sapling growth | 4.5 | 2.9 | 2.8 |
| Production + water | 5.1 | 6.6 | 6.5 |
| Outputs | 23.9 | 24.8 | 23.8 |
| Management script | 5.4 | 5.7 | 5.8 |

**Thread scaling, 150 years** (model time, seconds)

| Build | 1 | 4 | 8 | all (28) |
|---|---|---|---|---|
| Upstream iLand (CPU) |  | 55.7 | 60.6 | 43.0 |
| CPU fixes | 132.5 | 45.8 | 37.7 | 32.3 |
| CPU fixes + GPU |  | 42.8 | 26.2 | 19.9 |

**Throughput, 150-year runs** (several runs side by side on one 28-core node with one GPU)

| Build | 1 run x 28 threads | 4 runs x 7 threads |
|---|---|---|
| Upstream iLand (CPU) | 61 runs/h | 204 runs/h |
| CPU fixes | 86 runs/h | 273 runs/h |
| CPU fixes + GPU | 118 runs/h | 320 runs/h |

- **Thread scaling:** upstream gets no reliably faster beyond 4–8 threads, and its timings
  jump around between runs, because how long threads queue for the shared counter depends on
  timing. With the fixes, one run goes from 132 s on 1 thread to 32 s on 28, flattening beyond
  8 threads. That's why running several replicates side by side pays off.
- **Throughput:** four 7-thread runs instead of one 28-thread run give 3.3x (upstream),
  3.2x (CPU fixes) and 2.7x (GPU; all four runs share one GPU) more runs per hour.
- **Where the time goes:** the GPU build spends under 1 s of 300 years on seed dispersal
  (from 30 s). Establishment drops from 49 s to 10 s with the CPU fixes. Most of what
  remains is outputs (24 s, SQLite), tree growth and establishment, all on the CPU.

**With fire on** (realistic settings; 300 years, all 28 cores; median of 6/6/5 seeds; one more GPU run crashed in year 1 on the `DebugTimer` race, fixed since)

| Build | Wall time | Model time | Speed-up (wall) |
|---|---|---|---|
| Upstream iLand (CPU) | 2.5 min | 2.4 min | 1.00x |
| CPU fixes | 2.0 min | 1.9 min | 1.25x |
| CPU fixes + GPU | 1.5 min | 1.3 min | 1.74x |

### Do the builds simulate the same forest?

iLand is stochastic, and its multithreaded runs are not reproducible even with a fixed seed.
So the test is whether the differences between builds stay within the run-to-run spread.

- **Single-threaded:** the CPU fixes give output identical to upstream with a fixed seed,
  verified table by table.
- **GPU light competition:** checked year by year against the CPU (`ILAND_GPU_VALIDATE=1`,
  see [gpu/README.md](gpu/README.md)).
- **Whole runs:** landscape means over years 280–300 of the 300-year runs, with fire off and
  on (`benchmarks/compare_outputs.py`):

**Fire off** (3 runs per build; mean ± standard deviation):

| Species | Measure | Upstream | CPU fixes | CPU fixes + GPU |
|---|---|---|---|---|
| White spruce | stems/ha | 21.2 ± 0.93 | 22.6 ± 0.31 | 22.5 ± 0.056 |
| White spruce | basal area m2/ha | 1.39 ± 0.041 | 1.44 ± 0.015 | 1.44 ± 0.0035 |
| White spruce | volume m3/ha | 13.3 ± 0.37 | 13.8 ± 0.14 | 13.8 ± 0.049 |
| Black spruce | stems/ha | 294 ± 7 | 301 ± 1.5 | 303 ± 0.97 |
| Black spruce | basal area m2/ha | 2.82 ± 0.082 | 2.86 ± 0.018 | 2.89 ± 0.01 |
| Black spruce | volume m3/ha | 9.61 ± 0.3 | 9.73 ± 0.063 | 9.86 ± 0.038 |

**Fire on** (realistic settings), with single-threaded upstream as a reference where no threads race for the random numbers:

| Build | Runs | Fires per run | Burned area per run (median) | Runs with a fire > 100 ha |
|---|---|---|---|---|
| Upstream | 8 | 0.38 | 0 ha | 2 |
| Upstream, 1 thread | 6 | 0.83 | 1 ha | 2 |
| CPU fixes | 6 | 1.00 | 117 ha | 3 |
| CPU fixes + GPU | 5 | 0.80 | 246 ha | 3 |

| Species | Measure | Upstream | Upstream, 1 thread | CPU fixes | CPU fixes + GPU |
|---|---|---|---|---|---|
| White spruce | stems/ha | 21.6 ± 0.61 | 65.5 ± 67 | 26.2 ± 6 | 24.1 ± 2.5 |
| White spruce | basal area m2/ha | 1.39 ± 0.039 | 2.34 ± 1.4 | 1.55 ± 0.18 | 1.51 ± 0.074 |
| White spruce | volume m3/ha | 13.3 ± 0.4 | 18.6 ± 7.7 | 14.6 ± 1.4 | 14.3 ± 0.63 |
| Black spruce | stems/ha | 296 ± 4.4 | 471 ± 320 | 309 ± 15 | 309 ± 6.5 |
| Black spruce | basal area m2/ha | 2.83 ± 0.05 | 3.81 ± 2.1 | 2.89 ± 0.056 | 2.92 ± 0.021 |
| Black spruce | volume m3/ha | 9.67 ± 0.18 | 12.2 ± 5.8 | 9.77 ± 0.14 | 9.91 ± 0.049 |

Aspen and birch are almost absent without fire and are left out (all rows are in
`compare_outputs.py`'s output).

- **With fire off, the two patched builds agree to about 1%.** The GPU build has about 1% more
  black-spruce volume. That fits its complete height grid, which removes upstream's extra
  shading at resource-unit edges.
- **Multithreaded upstream is 2–6% lower and varies more between runs** (white spruce
  ±0.9 stems/ha, against ±0.3 and ±0.06). That fits its threads racing on one random-number
  index: some draw the same numbers, which correlates randomness across resource units. Three
  runs per build is few, though.
- **With fire on, fire history dominates.** One large fire roughly triples the number of trees
  for decades. Multithreaded upstream had fewer fires (0.38 per run) than the patched builds
  (1.0 and 0.8), but single-threaded upstream, where no threads race for random numbers, had
  0.83, like the patched builds. So the patches don't change fire behaviour; multithreaded
  upstream's low rate is either chance (p ≈ 0.08) or another effect of its racy generator.

### Caveats

- **Proxy test case:** the benchmark is CPCRW-like, not CPCRW. Real-landscape timings, and the
  best `ILAND_PARALLEL` and `ILAND_THREADS` on Derecho, should be checked with a few runs
  there.
- **GPU results are statistically equivalent, not bit-identical.** Long-distance seed
  dispersal uses the GPU's own random numbers.
- **Upstream ordering quirk:** the GPU computes light competition with a complete height grid.
  Upstream builds it one resource unit at a time, interleaved with applying the patterns, which
  changes some trees' light by up to 128% (see [gpu/README.md](gpu/README.md)). This quirk of
  upstream iLand is worth raising with its developers, as are the three thread-safety bugs.
- **Torus mode** stays on the CPU.

### Reproduce

```bash
curl -O https://iland-model.org/downloads/example_bgd.zip && unzip example_bgd.zip  # 715 MB
python3 benchmarks/make_cpcrw_like.py example_bgd cpcrw_like
# bin/ holds ilandc_upstream (plain iLand at 4dd4e6f), ilandc_cpuopt and ilandc_gpu (gpu/build_iland.sh)
benchmarks/run_matrix.sh bin cpcrw_like modules.fire.enabled=false
RESULTS_CSV=$PWD/benchmarks/results_with_fire.csv THROUGHPUT_CSV=$PWD/benchmarks/throughput_with_fire.csv \
    benchmarks/run_matrix.sh bin cpcrw_like
python3 benchmarks/summarise.py
python3 benchmarks/compare_outputs.py cpcrw_like
```

### Contributing

Contributions to the scripts are welcome. To contribute:

1. Fork the repository and create a new branch for your changes.
2. Follow the existing code style and naming conventions used in the scripts.
3. Test your changes on an HPC environment before submitting.
4. Open a pull request with a clear description of what your changes do and why.

If you are adding a new script, please add a brief description of it to this README under the **Scripts** section.
