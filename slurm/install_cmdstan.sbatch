#!/bin/bash
#SBATCH --job-name=cmdstan-install
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=2
#SBATCH --mem=12G
#SBATCH --time=01:30:00
#SBATCH --output=logs/%x-%j.out
# cmdstanr + brms into the user library, CmdStan into ~/.cmdstan (shared home),
# then a tiny OpenCL smoke test on the T4.
set -e
cd $SLURM_SUBMIT_DIR
Rscript -e '
install.packages("cmdstanr", repos = c("https://stan-dev.r-universe.dev", "https://p3m.dev/cran/latest"))
install.packages(c("brms", "posterior"), repos = "https://p3m.dev/cran/latest", Ncpus = 2)
cmdstanr::install_cmdstan(cores = 2, quiet = TRUE)
cat("CmdStan", cmdstanr::cmdstan_version(), "at", cmdstanr::cmdstan_path(), "\n")'
nvidia-smi -L
Rscript -e '
library(cmdstanr)
m <- cmdstan_model("stan/logit_glm.stan", cpp_options = list(stan_opencl = TRUE),
                   exe_file = "stan/logit_glm_opencl")
set.seed(1); N <- 2000; X <- matrix(rnorm(N * 3), N); y <- rbinom(N, 1, plogis(X %*% c(1, -1, 0.5)))
f <- m$sample(data = list(N = N, K = 3, X = X, y = y), chains = 1, iter_warmup = 200,
              iter_sampling = 200, opencl_ids = c(0, 0), refresh = 0, show_messages = FALSE)
print(f$summary("beta"))'
