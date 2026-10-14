# 08 -- Task granularity: how much work per task? -------------------------------
#
# Same total work as 05_ (40 sites x SCALING_N_BOOT resamples), cut into tasks
# of different sizes:
#   * one site per task  -> 40 unequal tasks, the largest site sets the floor
#   * chunks of resamples -> many equal-sized tasks, combined per site afterwards
#   * one resample per task -> per-task overhead dominates
# and the site data either travels with every task or is sent once per daemon.

source("R/00_config.R")
library(mirai)

cohort    <- readRDS("data/cohort.rds")
site_list <- split(cohort, cohort$site)
site_list <- site_list[order(vapply(site_list, nrow, integer(1)), decreasing = TRUE)]
resources <- readRDS("results/resources.rds")

daemon_counts <- if (USE_SLURM) GRANULARITY_DAEMONS else
  GRANULARITY_DAEMONS[GRANULARITY_DAEMONS <= parallelly::availableCores()]

# Chunked tasks use the shared helpers from R/functions.R (make_chunks(),
# bootstrap_chunk(), combine_chunks()). The "data per task" variant needs its
# own task function -- defined at top level: a function created *inside*
# another one serialises that function's environment with every task (in a
# first version: the whole task table, ~900 KB per task, ~35 GB for 40,000 tasks).
task_data_per_task <- function(site_df, n_boot, bootstrap_site) {
  bootstrap_site(site_df, n_boot, draws = TRUE)
}

run_variant <- function(chunk, data_once) {
  tasks <- make_chunks(site_list, SCALING_N_BOOT, chunk)
  t <- system.time(
    draws <- if (data_once) {
      # site_list already lives on every daemon: tasks only carry a site name
      mirai_map(tasks, bootstrap_chunk)[.stop]
    } else {
      # every task carries its site's data frame
      mirai_map(site_list[tasks$site], task_data_per_task,
                .args = list(n_boot = chunk, bootstrap_site = bootstrap_site))[.stop]
    }
  )[["elapsed"]]
  list(seconds = t, tasks = nrow(tasks), result = combine_chunks(tasks, draws, site_list))
}

variants <- data.frame(
  label     = c("1 site per task", "100 resamples per task", "100 resamples per task",
                "10 resamples per task", "1 resample per task"),
  chunk     = c(SCALING_N_BOOT, 100, 100, 10, 1),
  data_once = c(FALSE, FALSE, TRUE, TRUE, TRUE)
)

granularity <- lapply(daemon_counts, function(n) {
  start_daemons(n, resources, use_slurm = USE_SLURM, partition = SLURM_PARTITION,
                account = SLURM_ACCOUNT, rscript = RSCRIPT, extra = SLURM_EXTRA)
  on.exit(daemons(0))
  # ~90 MB per daemon, once -- instead of a site's data with every task
  everywhere({}, site_list = site_list, bootstrap_site = bootstrap_site)[]

  do.call(rbind, lapply(seq_len(nrow(variants)), function(i) {
    v   <- variants[i, ]
    res <- run_variant(v$chunk, v$data_once)
    message(sprintf("n = %2d | %-23s | data %-8s | %5d tasks | %6.1fs",
                    n, v$label, if (v$data_once) "once" else "per task", res$tasks, res$seconds))
    data.frame(daemons = n, v, tasks = res$tasks, seconds = res$seconds,
               hr_site_31 = res$result$hr[res$result$site == "site_31"])
  }))
})
granularity <- do.call(rbind, granularity)

# Speedup against the single-daemon run from 05_ (same total work)
scaling <- read.csv("results/scaling.csv")
granularity$speedup    <- scaling$compute_s[scaling$daemons == 1] / granularity$seconds
granularity$efficiency <- granularity$speedup / granularity$daemons
granularity

write.csv(granularity, "results/granularity.csv", row.names = FALSE)
