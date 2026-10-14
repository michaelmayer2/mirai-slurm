#!/bin/bash
#SBATCH --job-name=gpu-install
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=2
#SBATCH --mem=12G
#SBATCH --time=01:00:00
#SBATCH --output=logs/%x-%j.out
# GPU-specific R packages go into their own library, so the CPU packages in the
# normal user library stay untouched. Jobs that need them set R_LIBS_USER.
set -e
GPU_LIB=$HOME/R/gpu-library
export R_LIBS_USER=$GPU_LIB:$HOME/R/x86_64-pc-linux-gnu-library/4.6
cd /tmp
# xgboost: experimental GPU build from the release branch (not on CRAN)
curl -sSfLo xgboost_r_gpu_linux.tar.gz \
  https://s3-us-west-2.amazonaws.com/xgboost-nightly-builds/release_3.4.0/6abe39953954f23fd8b9408283294bf630f1ec7b/xgboost_r_gpu_linux.tar.gz
Rscript -e 'install.packages(c("data.table", "jsonlite"), repos = "https://p3m.dev/cran/latest")'
R CMD INSTALL -l $GPU_LIB xgboost_r_gpu_linux.tar.gz
# torch: pre-built binary with CUDA 12.8 + cuDNN bundled
Rscript -e '
options(timeout = 1200)
version <- available.packages(repos = "https://cloud.r-project.org")["torch", "Version"]
options(repos = c(torch = sprintf("https://torch-cdn.mlverse.org/packages/cu128/%s/", version),
                  CRAN = "https://p3m.dev/cran/latest"))
install.packages("torch", lib = Sys.getenv("HOME") |> file.path("R/gpu-library"))'
nvidia-smi --query-gpu=name,memory.total --format=csv
Rscript -e '
library(xgboost); cat("xgboost", format(packageVersion("xgboost")), "\n")
x <- matrix(rnorm(2e5), ncol = 10); y <- rbinom(2e4, 1, 0.5)
m <- xgb.train(params = list(objective = "binary:logistic", device = "cuda", tree_method = "hist"),
               data = xgb.DMatrix(x, label = y), nrounds = 5)
cat("xgboost on cuda: ok\n")
library(torch); cat("torch", format(packageVersion("torch")), "cuda:", cuda_is_available(), "\n")
print(torch_randn(2, 2, device = "cuda"))'
