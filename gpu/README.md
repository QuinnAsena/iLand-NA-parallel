# iLand on the GPU: patches, build, validation

This folder holds three patches for [iLand](https://github.com/edfm-tum/iland-model)
(commit `4dd4e6f`, iLand 2.2) and a script that builds a patched `ilandc`. Results
and recommendations are in the main [README](../README.md#performance-gpu-and-benchmarks).

| Patch | What it changes |
|---|---|
| `0001` | `ilandc` applies `system.settings.debugOutput`, as the GUI does. Without it, the console never writes iLand's per-year performance table (512). |
| `0002` | Fixes three thread-safety problems in multithreaded runs (CPU only). (1) All threads shared one random-number index, so they queued for it; now the main thread keeps upstream's sequence and every other thread has its own Mersenne Twister. (2) A debug counter that every seed-dispersal thread wrote is compiled out of the console build. (3) `DebugTimer` looked up its global table without a lock, which crashed one run in about 45 (year 1, when the per-species seed-dispersal threads create their first timers together). Single-threaded runs give exactly the same results as upstream. |
| `0003` | An optional CUDA path (`qmake CONFIG+=cuda`) for light competition and seed dispersal. |

The patches are derived from iLand and, like iLand, are licensed under the
GNU GPL v3 or later. This repository's MIT licence covers its own scripts.

## Build

```bash
# Qt 6.8 + FreeImage via pixi (or use your own Qt 6.5-6.8); nvcc from the system (e.g. module load cuda)
pixi run --manifest-path gpu/pixi.toml gpu/build_iland.sh ~/iland-build
# -> ~/iland-build/bin/ilandc_cpu and, if nvcc is found, ~/iland-build/bin/ilandc_gpu
```

The script clones iLand, checks out the pinned commit, applies the patches, and builds
the plugins plus two console versions.

- **Architectures:** the GPU build compiles for all major GPU generations by default.
  Set `CUDA_ARCH="-arch=sm_80"` to build for A100s only (faster to compile).
- **Runtime libraries:** the CUDA runtime is linked statically, so compute nodes need only
  the NVIDIA driver.
- **Qt version:** Qt 6.12 is too new for iLand 2.2 (moc fails on `bite/biteagent.h`).

## Run

Use `ilandc_gpu` exactly like `ilandc`; project files and command-line keys are unchanged.

- **Device selection:** if it finds a CUDA device, it runs light competition and seed
  dispersal there, and prints the device name at the start of the log.
- **Fallback:** without a device, or with `ILAND_GPU=0`, it behaves like `ilandc_cpu`. On any
  CUDA error it logs a warning and carries on on the CPU.
- **Several GPUs:** select one per process with `CUDA_VISIBLE_DEVICES`
  (`scripts/run_iland_csv_cpxml.sh` does this with `ILAND_GPUS`).
- **Sharing one GPU:** several runs can share a GPU. Each 300-year run of the 5.5 x 7.5 km
  test landscape used at most 490 MiB of GPU memory, most of it the CUDA context. For the
  25.5 x 23.9 km CPCRW landscape add about 0.7 GB for its 12,950 x 12,150-cell light grid and
  the trees: roughly 1.2 GB per run, so an 80 GB A100 holds many runs.

## What runs on the GPU

- **Light competition** (`Model::applyPattern`/`readPattern`), every year:
  - initialise the 2 m light (LIF) grid;
  - build the 10 m height grid (tree counts, dominant and stem heights);
  - multiply every tree's light influence pattern into the grid;
  - compute each tree's raw light sum.

  The species-specific LRI correction (a project-file expression) and the per-resource-unit
  sums stay on the CPU. Both grids are copied back every year, because establishment,
  sapling growth and outputs read them.
- **Seed dispersal** (`SeedDispersal::distributeSeeds`), per species and year: the kernel
  convolution, long-distance dispersal and the final scaling.
- **Torus mode** stays on the CPU, for both.

Everything else (tree growth, 3-PG, water and permafrost, establishment, sapling growth,
fire, outputs) stays on the CPU. Those parts are branchy per-tree or per-cell code that
creates and removes trees, which doesn't map well onto a GPU.

## How close GPU results are to the CPU

**Light competition.** Run with `ILAND_GPU_VALIDATE=1` and every year the light competition
is recomputed on the CPU from the same trees and compared (slow; for testing only).

| Year (trees) | GPU vs CPU, same order: light grid, max abs. difference | Raw light sum, max rel. difference | Height grid | Upstream order vs same order: raw light sum, max rel. difference |
|---|---|---|---|---|
| 28 (21,014) | 2.4e-7 | 2.5e-7 | identical | 0.21 |
| 88 (114,305) | 3.0e-7 | 2.9e-7 | identical | 0.82 |
| 148 (280,764) | 4.2e-7 | 4.7e-7 | identical | 1.28 |

- **GPU vs CPU:** the GPU matches the CPU to float rounding. It's compiled without fused
  multiply-add, and the remaining differences come from the order of multiplications and sums.
- **Where results really differ is upstream's own ordering.** The CPU code builds the height
  grid one resource unit at a time, interleaved with applying the patterns, so trees near a
  unit's edge are shaded against neighbours that haven't entered their heights yet. The GPU
  (and the CPU check above) completes the height grid first. For some trees that changes the
  light sum by up to 128%. That is an ordering quirk of upstream iLand, also present in its
  multithreaded runs (where it depends on thread timing), and worth raising with the iLand
  developers.

**Seed dispersal.** Long-distance dispersal on the GPU uses the GPU's own random numbers
(Philox, seeded from iLand's generator), so GPU runs are statistically equivalent to CPU
runs, not bit-identical. Upstream multithreaded runs aren't reproducible either, even with a
fixed seed.

`benchmarks/compare_outputs.py` compares the forests simulated by the three builds; results
are in the main README.
