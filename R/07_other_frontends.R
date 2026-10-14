# 07 -- Same daemons, other front-ends ------------------------------------------
#
# purrr, furrr (futureverse) and base parallel can all run on mirai daemons.
# The daemons are what SLURM sizes, so everything from 03_ carries over: the
# same measured resources, the same "ship only what you need" rule.
# Unlike 04_/05_, one task = one whole site here (40 unequal tasks): that is
# what makes the difference between static chunks and one-task-at-a-time visible.

source("R/00_config.R")
library(mirai)

cohort    <- readRDS("data/cohort.rds")
site_list <- split(cohort, cohort$site)
site_list <- site_list[order(vapply(site_list, nrow, integer(1)), decreasing = TRUE)]
resources <- readRDS("results/resources.rds")

start_daemons(N_DAEMONS, resources, use_slurm = USE_SLURM,
              partition = SLURM_PARTITION, account = SLURM_ACCOUNT,
              rscript = RSCRIPT, extra = SLURM_EXTRA)

timings <- list()

# 1. purrr (>= 1.1) --------------------------------------------------------------
# in_parallel() ships a self-contained function: everything it uses is passed
# via `...` -- the same rule as mirai_map(.args = ...).
timings$purrr <- system.time(
  res_purrr <- purrr::map(site_list, purrr::in_parallel(
    \(d) bootstrap_site(d, n_boot = n_boot),
    bootstrap_site = bootstrap_site, n_boot = FRONTEND_N_BOOT
  ))
)[["elapsed"]]

# 2. furrr / futureverse -----------------------------------------------------------
# mirai_cluster uses the daemons that are already running (also works for
# future.apply, doFuture, ...).
future::plan(future.mirai::mirai_cluster)
timings$furrr <- system.time(
  res_furrr <- furrr::future_map(site_list, bootstrap_site, n_boot = FRONTEND_N_BOOT,
                                 .options = furrr::furrr_options(seed = TRUE))
)[["elapsed"]]
# Default scheduling = 1: one chunk per worker, fixed up front. With unequal
# tasks sorted largest first, chunk 1 gets all the big sites. Hand out one
# task at a time instead:
timings$furrr_one_at_a_time <- system.time(
  furrr::future_map(site_list, bootstrap_site, n_boot = FRONTEND_N_BOOT,
                    .options = furrr::furrr_options(seed = TRUE, scheduling = Inf))
)[["elapsed"]]
future::plan(future::sequential)

daemons(0)

# 3. base parallel ------------------------------------------------------------------
# A mirai cluster has its *own* daemons -- on SLURM, its own sbatch jobs, so
# give them the same measured options. Create the n nodes first, then launch
# one job per node: make_cluster(n, remote = cluster_config(...)) would take
# the node count from the config (= 1) and run parLapply() serially.
if (USE_SLURM) {
  dir.create("logs", showWarnings = FALSE)
  invisible(utils::capture.output(cl <- make_cluster(N_DAEMONS, url = host_url())))  # silence printed commands
  launch_remote(cl, remote = cluster_config(
    command = "sbatch", rscript = RSCRIPT,
    options = slurm_options(resources, partition = SLURM_PARTITION,
                            account = SLURM_ACCOUNT, extra = SLURM_EXTRA,
                            log_dir = file.path(getwd(), "logs"))
  )) |> invisible()
  while (status(cl)$connections < N_DAEMONS) Sys.sleep(2)   # jobs may sit in the queue
} else {
  cl <- parallel::makeCluster(N_DAEMONS, type = "MIRAI")   # R >= 4.5, or make_cluster()
}
stopifnot(length(cl) == N_DAEMONS)
timings$parallel <- system.time(
  res_parallel <- parallel::parLapply(cl, site_list, bootstrap_site, n_boot = FRONTEND_N_BOOT)
)[["elapsed"]]
# Same static chunking as furrr; chunk.size = 1 (or clusterApplyLB()) fixes it.
timings$parallel_one_at_a_time <- system.time(
  parallel::parLapply(cl, site_list, bootstrap_site, n_boot = FRONTEND_N_BOOT, chunk.size = 1)
)[["elapsed"]]
parallel::stopCluster(cl)

# 4. crew / crew.cluster (and targets) -----------------------------------------------
# crew launches and auto-scales its own mirai daemons as SLURM jobs (one job
# array) -- but the per-worker request still comes from your profile.
# Use the same controller in a targets pipeline via
# targets::tar_option_set(controller = controller).
if (USE_SLURM && requireNamespace("crew.cluster", quietly = TRUE)) {
  controller <- crew.cluster::crew_controller_slurm(
    name = "coxboot", workers = N_DAEMONS, seconds_idle = 60,
    options_cluster = crew.cluster::crew_options_slurm(
      partition = SLURM_PARTITION, cpus_per_task = resources$cpus,
      memory_gigabytes_per_cpu = resources$mem_mb / 1024 / resources$cpus,
      time_minutes = ceiling(resources$time_s / 60),
      script_lines = SLURM_EXTRA,
      log_output = file.path(getwd(), "logs", "crew-%A_%a.out")
    )
  )
  controller$start()
  # crew hands out one task at a time, like mirai_map()
  timings$crew <- system.time(
    res_crew <- controller$map(
      command = bootstrap_site(site_df, n_boot = n_boot),
      iterate = list(site_df = site_list),
      data = list(bootstrap_site = bootstrap_site, n_boot = FRONTEND_N_BOOT)
    )
  )[["elapsed"]]
  controller$terminate()
}

# Same answers (up to bootstrap noise -- each front-end uses its own RNG streams)
data.frame(frontend = names(timings), seconds = unlist(timings), row.names = NULL)
hr <- data.frame(
  site     = names(site_list),
  purrr    = vapply(res_purrr, `[[`, numeric(1), "hr"),
  furrr    = vapply(res_furrr, `[[`, numeric(1), "hr"),
  parallel = vapply(res_parallel, `[[`, numeric(1), "hr")
)
if (exists("res_crew")) {   # crew returns tasks in completion order
  crew_hr <- vapply(res_crew$result, `[[`, numeric(1), "hr")
  hr$crew <- crew_hr[match(hr$site, vapply(res_crew$result, `[[`, character(1), "site"))]
}
head(hr)

# Why the defaults are slow: rows per static chunk (one chunk per daemon)
sizes <- vapply(site_list, nrow, integer(1))
vapply(parallel::splitIndices(length(sizes), N_DAEMONS), function(i) sum(sizes[i]), numeric(1))
