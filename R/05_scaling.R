# 05 -- Scaling: what do we actually gain from more daemons? ----------------------
#
# Time the same workload on 1, 2, 4, ... daemons. Queue/start-up time is
# measured separately -- on a busy cluster it can dominate.

source("R/00_config.R")
library(mirai)

cohort    <- readRDS("data/cohort.rds")
site_list <- split(cohort, cohort$site)
site_list <- site_list[order(vapply(site_list, nrow, integer(1)), decreasing = TRUE)]
resources <- readRDS("results/resources.rds")
tasks     <- make_chunks(site_list, SCALING_N_BOOT, CHUNK_SIZE)   # 400 tasks

daemon_counts <- if (USE_SLURM) SCALING_DAEMONS else
  SCALING_DAEMONS[SCALING_DAEMONS <= parallelly::availableCores()]

scaling <- lapply(daemon_counts, function(n) {
  # time limit for this n: total work shared by n daemons (same rule as 03_)
  total_s <- resources$rate * SCALING_N_BOOT * sum(vapply(site_list, nrow, integer(1)))
  res_n   <- resources
  res_n$time_s <- ceiling(total_s / n * 2 + 300)
  res_n$time   <- slurm_time(res_n$time_s)

  # start-up = queue + connect + shipping the shared data once per daemon
  t_start <- system.time({
    start_daemons(n, res_n, use_slurm = USE_SLURM, partition = SLURM_PARTITION,
                  account = SLURM_ACCOUNT, rscript = RSCRIPT, extra = SLURM_EXTRA)
    everywhere({}, site_list = site_list, bootstrap_site = bootstrap_site)[]
  })[["elapsed"]]
  on.exit(daemons(0))

  t_run <- system.time(
    mirai_map(tasks, bootstrap_chunk)[.stop]
  )[["elapsed"]]

  message(sprintf("n = %2d: start-up %5.1fs, compute %6.1fs", n, t_start, t_run))
  data.frame(daemons = n, startup_s = t_start, compute_s = t_run)
})
scaling <- do.call(rbind, scaling)

scaling$speedup    <- scaling$compute_s[scaling$daemons == 1] / scaling$compute_s
scaling$efficiency <- scaling$speedup / scaling$daemons
scaling

write.csv(scaling, "results/scaling.csv", row.names = FALSE)
