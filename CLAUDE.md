# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Materials for a 60-minute workshop: distributing R code from Posit Workbench to a SLURM cluster with
`mirai`. The main teaching point is choosing the right resources: profile **one** task with `syrup`
before asking SLURM for N workers. The workload is a bootstrap Cox model per hospital site, on a
simulated 40-site cohort with unequal site sizes. One task = `CHUNK_SIZE` (100) resamples of one
site, so a task's size doesn't depend on `n_boot`. 07 deliberately keeps one site per task (unequal
tasks). Also: a "which tool when" section (one job / CPUs / GPU / optimise), GPU benchmarks (09)
and Quarto render modes (`quarto-demo/`). The audience already knows SLURM and the CLI.

## Commands

Dependencies: `install.packages(c("mirai", "syrup", "survival", "parallelly", "ggplot2", "cli", "scales", "purrr", "carrier", "furrr", "future.mirai", "lme4", "parsnip"))`;
`crew.cluster` is optional (needs the `libxml2-dev` system library).
On a cluster, compute nodes also need `mirai` and `survival` in a library they can see (e.g. a shared
`R_LIBS_USER`), and they must be able to reach the Workbench session at `host_url()`.

Run everything from the project root. Each script sources `R/00_config.R`, which sources `R/functions.R`.

```sh
Rscript R/01_simulate_cohort.R              # -> data/cohort.rds (needed by all later scripts)
Rscript R/03_profile_one_task.R             # -> results/resources.rds, profiles.rds, profile_*.png
N_BOOT=200 Rscript R/04_launch_slurm.R      # quick dry run
N_BOOT=200 SCALING_N_BOOT=200 Rscript R/05_scaling.R   # -> results/scaling.csv
Rscript R/06_plot_scaling.R                 # -> results/scaling_*.png
Rscript R/07_other_frontends.R              # purrr / furrr / parallel / crew on the same daemons
Rscript R/08_granularity.R                  # -> results/granularity.csv (reads scaling.csv from 05)
sbatch slurm/bench_cpu.sbatch; sbatch slurm/bench_gpu.sbatch   # R/09 -> results/gpu_benchmarks.csv (appends)
sbatch slurm/bench_stan_cpu.sbatch; sbatch slurm/bench_stan_gpu.sbatch   # R/10 CmdStan/brms OpenCL -> gpu_benchmarks.csv
bash quarto-demo/render_modes.sh            # -> results/quarto_modes.csv
cd slides && quarto render workshop.qmd     # revealjs deck
```

- The scripts must run in order: 04 and 05 read `results/resources.rds` from 03, and 06 reads `results/scaling.csv`.
- There are no tests. "Verification" means running the scripts and checking their output and figures.
- Running 06 (or 03) via `Rscript` also writes a stray `Rplots.pdf` from printed plots; it can be deleted.

## Architecture

- `R/00_config.R`: all cluster-specific values (partition, account, `RSCRIPT`, `SLURM_EXTRA`
  module lines, all marked `CHANGE ME`) and the problem size. `USE_SLURM` is TRUE only when
  `sbatch` is on the PATH. Otherwise `start_daemons()` falls back to local daemons, so the whole
  pipeline also runs on a laptop.
- `R/functions.R`: shared helpers. Everything in it must be serialisable to a fresh mirai daemon,
  so package calls are namespace-qualified and nothing reads globals.
  - `bootstrap_site()`: the unit of work. `keep_fits` and `n_cores` exist only to demo anti-patterns.
    `draws = TRUE` returns raw log-HRs; `summarise_boot()` combines them in the session (its summary
    duplicates `bootstrap_site()`'s, which must stay self-contained).
  - `make_chunks()`, `bootstrap_chunk()`, `combine_chunks()`: the chunked unit of work used by 03-05 and 08.
    `bootstrap_chunk()` is the one deliberate exception to "nothing reads globals": it uses
    `site_list` / `bootstrap_site` placed on each daemon by `everywhere()` (sent once per daemon;
    sending site data with all 2,000 tasks would queue ~4 GB in the 4 GB session).
  - `profile_task()`: starts a **fresh** single daemon on the `"profile"` compute profile and runs
    syrup around one task. Reusing a daemon or the interactive session inflates RSS readings.
  - `tidy_syrup()`: syrup snapshots every R process on the machine, so this filters to the
    daemon's PID and its forked children.
  - `summarise_profile()`, `slurm_options()`, `slurm_time()`.
  - `start_daemons()`: one sbatch job per daemon, with `idletime` and `walltime` set.
  - `wait_for_daemons()`: polls `info()`, because jobs may sit in the queue.
- `resources.rds` is a list (`task_s` = largest chunk, `rate` = s per resample per patient, `cpus`,
  `mem_mb`, `time_s`, `time`). It is the handoff from
  profiling (03) to launching (04/05).
- `slides/workshop.qmd`: code chunks use `eval: false`. Figures are embedded from `../results/*.png`,
  so the deck reflects whatever the scripts last produced. Code shown on slides is a simplified
  version of the scripts; update both together.
  The appendix slide holds a verbatim copy of `simulate_cohort()` from `R/functions.R`; keep them identical.

## Status

- The current numbers and figures come from an AWS Parallel Computing Service SLURM cluster
  (partition `compute`, 4-core / 14.8 GB nodes). The SLURM path (`cluster_config`, `sacct`) works there.
- Compute nodes power off after 10 idle minutes and take ~5-10 min to boot: warm them up before
  benchmarks, or `wait_for_daemons()` (600 s timeout) may give up.
- GPU partition `gpu`: 2 × g4dn (2 vCPU, 14.8 GB, 1 × T4; driver 595, CUDA 12.8–13.2 toolkits).
  `--gres=gpu:1` on the default partition is rerouted there. GPU R packages live in `~/R/gpu-library`;
  CmdStan in `~/.cmdstan` (OpenCL builds via `cpp_options = list(stan_opencl = TRUE)`). The GPU slides are a
  section at the end of the deck: the main focus is mirai.
- Numbers on slides are typed in from `results/*.csv` (and script output); update them when re-running.
- Don't spend effort tuning the numbers.
