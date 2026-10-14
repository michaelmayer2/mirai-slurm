# Workshop configuration -------------------------------------------------------
#
# Everything cluster-specific lives here. Lines marked CHANGE ME need to be
# adapted to your SLURM cluster before running 04_ and 05_.

source("R/functions.R")

# Use SLURM if sbatch is on the PATH, otherwise fall back to local daemons so
# every script also runs on a laptop.
USE_SLURM <- nzchar(Sys.which("sbatch"))

SLURM_PARTITION <- "compute"          # CHANGE ME, e.g. "cpu" -- see `sinfo -s`
SLURM_ACCOUNT   <- NULL               # CHANGE ME if your cluster needs --account

# Rscript on the compute nodes. Same path as this session if R lives on a
# shared filesystem; otherwise e.g. "/opt/R/4.5.1/bin/Rscript".
RSCRIPT <- file.path(R.home("bin"), "Rscript")

# Extra lines for the sbatch script, e.g. environment modules.
SLURM_EXTRA <- character()            # CHANGE ME, e.g. "module load R/4.5.1"

# Problem size -----------------------------------------------------------------
N_SITES        <- 40      # hospital sites
N_BOOT_TEST    <- 200     # resamples per site in the first test run (02_)
N_BOOT         <- as.integer(Sys.getenv("N_BOOT", 5000))           # resamples per site (production)
CHUNK_SIZE     <- 100     # resamples per task: one task = CHUNK_SIZE resamples of one site
N_BOOT_PROFILE <- 1000    # resamples per call in the profiling gotchas (03_)
N_DAEMONS      <- 8       # daemons for the production run in 04_

# Scaling experiment (05_): smaller problem so the 1-daemon run stays short
SCALING_N_BOOT  <- as.integer(Sys.getenv("SCALING_N_BOOT", 1000))
SCALING_DAEMONS <- c(1, 2, 4, 8, 16, 32)

# Other front-ends (07_): small problem, the point is the API, not the timing
FRONTEND_N_BOOT <- as.integer(Sys.getenv("FRONTEND_N_BOOT", 200))

# Task granularity (08_): same total work as 05_, cut into different task sizes
GRANULARITY_DAEMONS <- c(8, 24, 30)
