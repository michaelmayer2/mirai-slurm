# 04 -- Launch right-sized daemons on SLURM -------------------------------------

source("R/00_config.R")
library(mirai)

cohort    <- readRDS("data/cohort.rds")
site_list <- split(cohort, cohort$site)
resources <- readRDS("results/resources.rds")

# Largest tasks first: the dispatcher hands out tasks in order, so starting
# the long ones early avoids one big site finishing last on its own.
site_list <- site_list[order(vapply(site_list, nrow, integer(1)), decreasing = TRUE)]

# One sbatch job per daemon, each with the measured limits.
# (Requires the compute nodes to be able to reach this Workbench session
#  on the port chosen by host_url() -- check with your admins.)
start_daemons(N_DAEMONS, resources, use_slurm = USE_SLURM,
              partition = SLURM_PARTITION, account = SLURM_ACCOUNT,
              rscript = RSCRIPT, extra = SLURM_EXTRA)
info()

t_run <- system.time(
  results <- mirai_map(site_list, bootstrap_site,
                       .args = list(n_boot = N_BOOT))[.progress, .stop]
)[["elapsed"]]

results <- do.call(rbind, results)
head(results[order(results$hr), ])
cat(sprintf("%d sites on %d daemons in %.1f minutes\n",
            N_SITES, N_DAEMONS, t_run / 60))

daemons(0)    # release the SLURM allocations as soon as you are done
saveRDS(results, "results/site_hazard_ratios.rds")

# Close the loop: did we ask for the right amount? --------------------------------
# Compare what was requested (ReqMem, ReqCPUS, Timelimit) with what was used
# (MaxRSS, TotalCPU, Elapsed). Way over -> you blocked resources others could use.
# Way under / OOM / TIMEOUT -> go back to 03_.
if (USE_SLURM) {
  system(paste("sacct --name=mirai-coxboot -S today -X --units=M",
               "--format=JobID,State,ReqCPUS,ReqMem,Timelimit,Elapsed,TotalCPU"))
  system(paste("sacct --name=mirai-coxboot -S today --units=M",
               "--format=JobID,MaxRSS | grep batch"))
  # or per job: system("seff <jobid>")
}

# Alternative: Posit Workbench launcher ------------------------------------------
# Instead of writing sbatch options yourself, let Workbench submit the jobs
# through its Launcher (uses the cluster/profiles configured by your admins).
# The same measured resources apply:
#
# daemons(
#   N_DAEMONS,
#   url    = host_url(),
#   remote = http_config(cpus = resources$cpus, memory = resources$mem_mb),
#   seed   = 42
# )
