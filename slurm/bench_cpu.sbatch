#!/bin/bash
#SBATCH --job-name=bench-cpu
#SBATCH --partition=compute
#SBATCH --cpus-per-task=4
#SBATCH --mem=13G
#SBATCH --time=01:00:00
#SBATCH --output=logs/%x-%j.out
# GPU-capable packages (xgboost GPU build, torch cu128) from their own library
export R_LIBS_USER=$HOME/R/gpu-library:$HOME/R/x86_64-pc-linux-gnu-library/4.6
export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK OPENBLAS_NUM_THREADS=$SLURM_CPUS_PER_TASK
cd $SLURM_SUBMIT_DIR
[ -x "$(command -v nvidia-smi)" ] && nvidia-smi -L
Rscript R/09_gpu_benchmarks.R
