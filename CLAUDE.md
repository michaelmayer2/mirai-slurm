# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Materials for a 45-minute workshop: distributing R code from Posit Workbench to a SLURM cluster with
`mirai`. The main teaching point is choosing the right resources: profile **one** task with `syrup`
before asking SLURM for N workers. The workload is a bootstrap Cox model per hospital site, on a
simulated 40-site cohort with unequal site sizes. One site is one independent task. The audience
already knows SLURM and the CLI.

## Commands

Dependencies: `install.packages(c("mirai", "syrup", "survival", "ggplot2", "cli", "scales"))`.
On a cluster, compute nodes also need `mirai` and `survival` in a library they can see (e.g. a shared
`R_LIBS_USER`), and they must be able to reach the Workbench session at `host_url()`.

Run everything from the project root. Each script sources `R/00_config.R`, which sources `R/functions.R`.

```sh
Rscript R/01_simulate_cohort.R              # -> data/cohort.rds (needed by all later scripts)
Rscript R/03_profile_one_task.R             # -> results/resources.rds, profiles.rds, profile_*.png
N_BOOT=200 Rscript R/04_launch_slurm.R      # quick dry run
N_BOOT=200 SCALING_N_BOOT=200 Rscript R/05_scaling.R   # -> results/scaling.csv
Rscript R/06_plot_scaling.R                 # -> results/scaling_*.png
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
  - `profile_task()`: starts a **fresh** single daemon on the `"profile"` compute profile and runs
    syrup around one task. Reusing a daemon or the interactive session inflates RSS readings.
  - `tidy_syrup()`: syrup snapshots every R process on the machine, so this filters to the
    daemon's PID and its forked children.
  - `summarise_profile()`, `slurm_options()`, `slurm_time()`.
  - `start_daemons()`: one sbatch job per daemon, with `idletime` and `walltime` set.
  - `wait_for_daemons()`: polls `info()`, because jobs may sit in the queue.
- `resources.rds` is a list (`task_s`, `cpus`, `mem_mb`, `time_s`, `time`). It is the handoff from
  profiling (03) to launching (04/05).
- `slides/workshop.qmd`: code chunks use `eval: false`. Figures are embedded from `../results/*.png`,
  so the deck reflects whatever the scripts last produced. Code shown on slides is a simplified
  version of the scripts; update both together.

## Status

- The current numbers and figures come from a laptop dry run.
- The SLURM path (`cluster_config`, `sacct`) has not been run on a real cluster yet. The user will
  refine timings and headroom factors on their cluster.
- Don't spend effort tuning the numbers.
