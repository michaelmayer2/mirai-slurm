# 04 -- Launch right-sized daemons on SLURM -------------------------------------

source("R/00_config.R")
library(mirai)

cohort    <- readRDS("data/cohort.rds")
site_list <- split(cohort, cohort$site)
resources <- readRDS("results/resources.rds")

# Largest tasks first: the dispatcher hands out tasks in order, so starting
# the long ones early avoids a big chunk finishing last on its own.
site_list <- site_list[order(vapply(site_list, nrow, integer(1)), decreasing = TRUE)]

# One task = CHUNK_SIZE resamples of one site: N_BOOT = 5000 -> 2,000 tasks.
tasks <- make_chunks(site_list, N_BOOT, CHUNK_SIZE)
nrow(tasks)

# One sbatch job per daemon, each with the measured limits.
# (Requires the compute nodes to be able to reach this Workbench session
#  on the port chosen by host_url() -- check with your admins.)
start_daemons(N_DAEMONS, resources, use_slurm = USE_SLURM,
              partition = SLURM_PARTITION, account = SLURM_ACCOUNT,
              rscript = RSCRIPT, extra = SLURM_EXTRA)
info()

# Ship the shared data once per daemon; each task then only carries a site name.
# (Sending each site's data with all 2,000 tasks would queue ~4 GB in this session.)
everywhere({}, site_list = site_list, bootstrap_site = bootstrap_site)[]

t_run <- system.time(
  draws <- mirai_map(tasks, bootstrap_chunk)[.progress, .stop]
)[["elapsed"]]

results <- combine_chunks(tasks, draws, site_list)
head(results[order(results$hr), ])
cat(sprintf("%d tasks (%d sites x %d resamples) on %d daemons in %.1f minutes\n",
            nrow(tasks), N_SITES, N_BOOT, N_DAEMONS, t_run / 60))

daemons(0)    # release the SLURM allocations as soon as you are done
saveRDS(results, "results/site_hazard_ratios.rds")

# Close the loop: did we ask for the right amount? --------------------------------
# Compare what was requested (ReqMem, ReqCPUS, Timelimit) with what was used
# (MaxRSS, TotalCPU, Elapsed). Way over -> you blocked resources others could use.
# Way under / OOM / TIMEOUT -> go back to 03_.
if (USE_SLURM) {
  # Usage (TotalCPU, MaxRSS) is recorded on the .batch step line of each job.
  system(paste("sacct --name=mirai-coxboot -S today --units=M",
               "--format=JobID,State,ReqCPUS,ReqMem,Timelimit,Elapsed,TotalCPU,MaxRSS",
               "| grep -v extern"))
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
