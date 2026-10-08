# mirai on SLURM: with great power comes great responsibility

Materials for a 45-minute workshop on distributing R code from Posit Workbench
to a SLURM cluster with [mirai](https://mirai.r-lib.org), and on right-sizing
the resource request by profiling a single task with
[syrup](https://simonpcouch.github.io/syrup/).

Scenario: bootstrap confidence intervals for a per-site Cox model on a
simulated 40-hospital patient cohort. Each site is one independent task.

## Setup

```r
install.packages(c("mirai", "syrup", "survival", "ggplot2", "cli", "scales"))
```

The compute nodes need the same packages (at least `mirai` and `survival`)
in a library they can see, e.g. a shared `R_LIBS_USER`.

Edit the `CHANGE ME` lines in `R/00_config.R` (partition, account, Rscript
path, module loads). If `sbatch` is not on the PATH, the scripts fall back to
local daemons, so everything also runs on a laptop.

## Running

Run from the project root, in order:

| script | what | workshop section |
|---|---|---|
| `R/01_simulate_cohort.R` | simulate the cohort → `data/cohort.rds` | problem |
| `R/02_serial_baseline.R` | time one site, extrapolate the serial runtime | problem |
| `R/03_profile_one_task.R` | profile one task in one daemon with syrup, 3 gotchas, derive resources → `results/resources.rds` | responsibility |
| `R/04_launch_slurm.R` | launch right-sized daemons, run, check `sacct` | SLURM |
| `R/05_scaling.R` | time the run on 1, 2, 4, … daemons → `results/scaling.csv` | scaling |
| `R/06_plot_scaling.R` | speedup / efficiency plots | scaling |

Problem size is set in `R/00_config.R`. `N_BOOT` and `SCALING_N_BOOT` can
be overridden with environment variables for quick dry runs:

```sh
N_BOOT=200 SCALING_N_BOOT=200 Rscript R/05_scaling.R
```

Slides: `quarto render slides/workshop.qmd`. Figures come from `results/`, so
run 03, 05 and 06 first (the numbers in the slides are from a laptop dry run
and should be refreshed on the cluster).
