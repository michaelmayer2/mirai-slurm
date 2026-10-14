#!/bin/bash
#SBATCH --job-name=cudaml-install
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=01:00:00
#SBATCH --output=logs/%x-%j.out
# cuda.ml (RAPIDS cuML for R) into the GPU library; cuda_ml_install() fetches
# its pinned CUDA + cuML runtime (~1.6 GB) once.
export R_LIBS_USER=$HOME/R/gpu-library:$HOME/R/x86_64-pc-linux-gnu-library/4.6
Rscript -e '
options(timeout = 1800)
install.packages("cuda.ml", lib = file.path(Sys.getenv("HOME"), "R/gpu-library"),
                 repos = "https://p3m.dev/cran/latest")
cuda.ml::cuda_ml_install()
library(parsnip)
d <- data.frame(x1 = rnorm(1e4), x2 = rnorm(1e4)); d$y <- factor(rbinom(1e4, 1, plogis(d$x1)))
f <- logistic_reg() |> set_engine("cuda.ml") |> fit(y ~ ., data = d)
print(f)'
