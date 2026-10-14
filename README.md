# mirai on SLURM: with great power comes great responsibility

Materials for a 45-minute workshop on distributing R code from Posit Workbench
to a SLURM cluster with [mirai](https://mirai.r-lib.org), and on right-sizing
the resource request by profiling a single task with
[syrup](https://simonpcouch.github.io/syrup/).

Scenario: bootstrap confidence intervals for a per-site Cox model on a
simulated 40-hospital patient cohort. It runs fine with 200 resamples; the real
analysis needs 5,000. One task = 100 resamples of one site, so the task size
(and the resource request) stays the same however large `n_boot` gets.

Also covered: which tool when (one job, CPUs, GPU, or optimise), measured GPU
benchmarks for the models a frequentist shop uses, and how Quarto renders map
onto SLURM allocations.

## Setup

```r
install.packages(c("mirai", "syrup", "survival", "parallelly", "ggplot2", "cli", "scales",
                   "purrr", "carrier", "furrr", "future.mirai", "lme4", "parsnip"))
install.packages("crew.cluster")   # optional, needs the libxml2-dev system library
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
| `R/02_serial_baseline.R` | time the 200-resample test run, extrapolate to 5,000 × 40 sites | problem |
| `R/03_profile_one_task.R` | profile one task in one daemon with syrup, 3 gotchas, derive resources → `results/resources.rds` | responsibility |
| `R/04_launch_slurm.R` | launch right-sized daemons, run, check `sacct` | SLURM |
| `R/05_scaling.R` | time the run on 1, 2, 4, … daemons → `results/scaling.csv` | scaling |
| `R/06_plot_scaling.R` | speedup / efficiency plots | scaling |
| `R/07_other_frontends.R` | the same run via purrr `in_parallel()`, furrr + future.mirai, `make_cluster()` + `launch_remote()` (base parallel), crew.cluster if installed | wrap-up |
| `R/08_granularity.R` | same work cut into 40 … 40,000 tasks, at 8 / 24 / 30 daemons → `results/granularity.csv` | scaling |
| `R/09_gpu_benchmarks.R` | xgboost, tidymodels, GLMs (glm / torch / cuda.ml), Cox, glmer on CPU vs GPU: `sbatch slurm/bench_cpu.sbatch`, `sbatch slurm/bench_gpu.sbatch` → `results/gpu_benchmarks.csv` | which tool when |
| `R/10_cmdstan_opencl.R` | Bayesian logistic GLM (`stan/logit_glm.stan`, `bernoulli_logit_glm`) with CmdStan / brms on 1 CPU core vs OpenCL on the T4: `sbatch slurm/bench_stan_cpu.sbatch`, `sbatch slurm/bench_stan_gpu.sbatch` → `results/gpu_benchmarks.csv` | GPUs |
| `quarto-demo/render_modes.sh` | render `quarto-demo/report.qmd` six ways, record where it ran → `results/quarto_modes.csv` | Quarto + SLURM |

Problem size is set in `R/00_config.R`. `N_BOOT` and `SCALING_N_BOOT` can
be overridden with environment variables for quick dry runs:

```sh
N_BOOT=200 SCALING_N_BOOT=200 Rscript R/05_scaling.R
```

Slides: `quarto render slides/workshop.qmd`. Figures come from `results/`, so
run 03, 05 and 06 first. The current numbers and figures come from an AWS
Parallel Computing Service SLURM cluster (`compute`: 4-core / 14.8 GB m7a nodes;
`gpu`: g4dn nodes with 2 vCPU and one NVIDIA T4).

GPU packages are not on CRAN in GPU form. `sbatch slurm/install_gpu_packages.sbatch`
installs the xgboost GPU build and torch (CUDA 12.8) into `~/R/gpu-library`;
`sbatch slurm/install_cuda_ml.sbatch` adds cuda.ml, and `sbatch slurm/install_cmdstan.sbatch`
installs cmdstanr, brms and CmdStan (into `~/.cmdstan`). The benchmark jobs put that
library first on `R_LIBS_USER`.
