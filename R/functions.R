# Shared functions for the workshop -------------------------------------------
#
# Every function here is written so it can be shipped to a mirai daemon:
# all package calls are namespace-qualified (daemons start with no packages
# attached) and nothing relies on objects from the global environment.

# Simulate a multi-site patient cohort ----------------------------------------
#
# Each hospital site has its own baseline hazard and a slightly different
# treatment effect, so the per-site hazard ratios genuinely differ.
# `n_biomarkers` pads each patient record with lab values that the model does
# not use -- realistic "wide" EHR extracts, and it makes the memory cost of
# shipping data around visible.
# Site sizes vary (small community hospitals vs. large university hospitals),
# so tasks are deliberately *not* all the same size.
simulate_cohort <- function(n_sites = 40, min_patients = 2000, max_patients = 10000,
                            n_biomarkers = 50, seed = 2026) {
  set.seed(seed)
  site_sizes <- round(stats::runif(n_sites, min_patients, max_patients))
  n <- sum(site_sizes)

  site       <- rep(sprintf("site_%02d", seq_len(n_sites)), times = site_sizes)
  site_idx   <- rep(seq_len(n_sites), times = site_sizes)
  age        <- round(stats::rnorm(n, 65, 12))
  sex        <- factor(sample(c("F", "M"), n, replace = TRUE))
  comorbidity <- stats::rpois(n, 1.5)                 # Charlson-like index
  treatment  <- factor(stats::rbinom(n, 1, 0.5), labels = c("standard", "new"))

  site_log_hr   <- stats::rnorm(n_sites, log(0.75), 0.15)   # true per-site effect
  site_baseline <- stats::rnorm(n_sites, log(0.02), 0.3)

  lp <- site_baseline[site_idx] +
    site_log_hr[site_idx] * (treatment == "new") +
    0.03 * (age - 65) + 0.2 * (sex == "M") + 0.25 * comorbidity
  event_time  <- stats::rexp(n, rate = exp(lp))
  censor_time <- stats::runif(n, 0, 60)                # months of follow-up

  cohort <- data.frame(
    patient_id  = seq_len(n),
    site        = site,
    age         = age,
    sex         = sex,
    comorbidity = comorbidity,
    treatment   = treatment,
    time        = pmin(event_time, censor_time),
    event       = as.integer(event_time <= censor_time)
  )

  biomarkers <- matrix(stats::rnorm(n * n_biomarkers), ncol = n_biomarkers,
                       dimnames = list(NULL, sprintf("lab_%02d", seq_len(n_biomarkers))))
  cbind(cohort, biomarkers)
}

# The unit of work: bootstrap a Cox model for one hospital site -----------------
#
# Returns the hazard ratio for the new treatment with a percentile bootstrap CI.
# draws = TRUE returns the raw bootstrap log-HRs instead, so one site can be
# split into several smaller tasks and combined with summarise_boot() later.
#
# Two arguments exist purely to demonstrate bad habits in the profiling section:
#   keep_fits = TRUE  -> keeps every coxph object (memory grows with n_boot)
#   n_cores   > 1     -> nested parallelism inside the task (CPU oversubscription)
bootstrap_site <- function(site_df, n_boot = 1000, keep_fits = FALSE, n_cores = 1,
                           draws = FALSE) {
  formula <- survival::Surv(time, event) ~ treatment + age + sex + comorbidity
  n <- nrow(site_df)

  one_boot <- function(b) {
    idx <- sample.int(n, n, replace = TRUE)
    fit <- survival::coxph(formula, data = site_df[idx, ], model = keep_fits, x = keep_fits)
    if (keep_fits) fit else stats::coef(fit)[["treatmentnew"]]
  }

  boots <- if (n_cores > 1) {
    parallel::mclapply(seq_len(n_boot), one_boot, mc.cores = n_cores)
  } else {
    lapply(seq_len(n_boot), one_boot)
  }

  log_hr <- if (keep_fits) {
    vapply(boots, function(f) stats::coef(f)[["treatmentnew"]], numeric(1))
  } else {
    unlist(boots)
  }

  if (draws) return(log_hr)

  data.frame(
    site     = site_df$site[1],
    n        = n,
    events   = sum(site_df$event),
    hr       = exp(stats::median(log_hr)),
    hr_lower = exp(stats::quantile(log_hr, 0.025, names = FALSE)),
    hr_upper = exp(stats::quantile(log_hr, 0.975, names = FALSE)),
    n_boot   = n_boot
  )
}

# Same summary as bootstrap_site(), from draws combined over several tasks.
# Used in the session only -- bootstrap_site() must stay self-contained.
summarise_boot <- function(site_df, log_hr) {
  data.frame(
    site     = site_df$site[1],
    n        = nrow(site_df),
    events   = sum(site_df$event),
    hr       = exp(stats::median(log_hr)),
    hr_lower = exp(stats::quantile(log_hr, 0.025, names = FALSE)),
    hr_upper = exp(stats::quantile(log_hr, 0.975, names = FALSE)),
    n_boot   = length(log_hr)
  )
}

# Chunked tasks: one task = `chunk` resamples of one site -----------------------
#
# The task size stays the same however large n_boot gets: more resamples just
# means more tasks, so one profile is valid for any n_boot.

# One row per task, in the order of `site_list` (sort it largest site first).
make_chunks <- function(site_list, n_boot, chunk) {
  n_chunks <- ceiling(n_boot / chunk)
  site     <- rep(names(site_list), each = n_chunks)
  data.frame(site = site,
             n_boot = rep(c(rep(chunk, n_chunks - 1), n_boot - chunk * (n_chunks - 1)),
                          length(site_list)))
}

# One task. Reads `site_list` and `bootstrap_site` from the *daemon's* global
# environment -- the one exception to "nothing reads globals" in this file:
#   everywhere({}, site_list = site_list, bootstrap_site = bootstrap_site)
# ships the data once per daemon, so a task only carries a site name.
bootstrap_chunk <- function(site, n_boot) {
  bootstrap_site(site_list[[site]], n_boot, draws = TRUE)
}

# Combine the draws of all chunks into one result row per site.
combine_chunks <- function(tasks, draws, site_list) {
  draws <- split(unlist(draws), rep(tasks$site, lengths(draws)))
  do.call(rbind, lapply(names(site_list), function(s) summarise_boot(site_list[[s]], draws[[s]])))
}

# Profiling helpers -------------------------------------------------------------

# syrup() snapshots *every* R process on the machine (other users, your IDE, ...).
# Keep only this session and processes it forked, and convert units.
tidy_syrup <- function(res, pid = Sys.getpid()) {
  res <- res[!is.na(res$pid) & (res$pid == pid | res$ppid == pid), ]
  res$rss_mb  <- as.numeric(res$rss) / 1e6
  res$elapsed <- as.numeric(difftime(res$time, min(res$time), units = "secs"))
  res$role    <- ifelse(res$pid == pid, "daemon", "forked child")
  res
}

# Profile one task exactly the way it will run on the cluster: inside a single,
# freshly started mirai daemon. `fun` and its arguments are shipped to the
# daemon just like mirai_map() would do, and syrup watches the daemon process
# (plus anything it forks). A fresh daemon per call means earlier profiles
# cannot inflate the memory reading of later ones.
profile_task <- function(fun, ..., interval = 0.1, helpers = list()) {
  mirai::daemons(1, .compute = "profile")
  on.exit(mirai::daemons(0, .compute = "profile"))
  pid <- mirai::mirai(Sys.getpid(), .compute = "profile")[]
  # functions the task calls by name go into the daemon's global environment
  if (length(helpers)) {
    do.call(mirai::everywhere, c(list(quote({})), helpers, .compute = "profile"))
  }
  Sys.sleep(interval * 3)            # a few idle snapshots as baseline

  args <- list(...)
  res <- syrup::syrup(
    mirai::mirai(do.call(fun, args), .args = list(fun = fun, args = args),
                 .compute = "profile")[],
    interval = interval
  )
  tidy_syrup(res, pid = pid)
}

# Collapse a profile into the numbers that matter for a SLURM request.
summarise_profile <- function(prof) {
  per_snapshot <- stats::aggregate(
    cbind(pct_cpu = ifelse(is.na(pct_cpu), 0, pct_cpu), rss_mb) ~ id,
    data = prof, FUN = sum
  )
  data.frame(
    wall_s       = max(prof$elapsed),
    peak_rss_mb  = max(per_snapshot$rss_mb),
    mean_cpu_pct = mean(per_snapshot$pct_cpu[-1]),
    max_cpu_pct  = max(per_snapshot$pct_cpu),
    n_processes  = length(unique(prof$pid))
  )
}

# SLURM helpers -----------------------------------------------------------------

# Turn measured resources into #SBATCH lines for mirai::cluster_config().
# One sbatch job == one daemon, so these limits apply *per daemon*.
slurm_options <- function(resources, partition = NULL, account = NULL,
                          job_name = "mirai-coxboot", log_dir = "logs",
                          extra = character()) {
  c(
    sprintf("#SBATCH --job-name=%s", job_name),
    if (!is.null(partition)) sprintf("#SBATCH --partition=%s", partition),
    if (!is.null(account))   sprintf("#SBATCH --account=%s", account),
    sprintf("#SBATCH --cpus-per-task=%d", resources$cpus),
    sprintf("#SBATCH --mem=%dM", resources$mem_mb),
    sprintf("#SBATCH --time=%s", resources$time),
    sprintf("#SBATCH --output=%s/%%x-%%j.out", log_dir),
    # make sure BLAS/OpenMP inside the daemon respects the allocation
    "export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK",
    "export OPENBLAS_NUM_THREADS=$SLURM_CPUS_PER_TASK",
    extra
  ) |> paste(collapse = "\n")
}

# Format seconds as SLURM's D-HH:MM:SS.
slurm_time <- function(seconds) {
  seconds <- ceiling(seconds)
  sprintf("%d-%02d:%02d:%02d", seconds %/% 86400, (seconds %% 86400) %/% 3600,
          (seconds %% 3600) %/% 60, seconds %% 60)
}

# Start `n` daemons -- on SLURM (one sbatch job per daemon, with the resource
# limits we measured) or, for laptops and dry runs, on the local machine.
#  * idletime: a daemon with nothing to do exits and frees its allocation
#  * walltime: daemon stops itself shortly before SLURM would kill it
start_daemons <- function(n, resources, use_slurm, partition = NULL, account = NULL,
                          rscript = "Rscript", extra = character(), seed = 42,
                          log_dir = file.path(getwd(), "logs")) {
  if (!use_slurm) {
    mirai::daemons(n, seed = seed)
    return(wait_for_daemons(n))
  }
  dir.create(log_dir, showWarnings = FALSE)
  opts <- slurm_options(resources, partition = partition, account = account,
                        log_dir = log_dir, extra = extra)
  mirai::daemons(
    n,
    url      = mirai::host_url(),
    remote   = mirai::cluster_config(command = "sbatch", options = opts,
                                     rscript = rscript),
    seed     = seed,
    idletime = 5 * 60 * 1000,
    walltime = max(resources$time_s - 120, 60) * 1000
  )
  wait_for_daemons(n)
}

# Block until `n` daemons have dialled in (SLURM jobs may sit in the queue).
wait_for_daemons <- function(n, timeout = 600, .compute = NULL) {
  start <- Sys.time()
  repeat {
    connected <- mirai::info(.compute = .compute)[["connections"]]
    if (connected >= n) break
    waited <- as.numeric(difftime(Sys.time(), start, units = "secs"))
    if (waited > timeout) {
      stop(sprintf("only %d of %d daemons connected after %ds -- check squeue",
                   connected, n, timeout), call. = FALSE)
    }
    message(sprintf("\r%d/%d daemons connected (%.0fs)", connected, n, waited),
            appendLF = FALSE)
    Sys.sleep(2)
  }
  message(sprintf("\n%d daemons connected after %.0fs", n,
                  as.numeric(difftime(Sys.time(), start, units = "secs"))))
  invisible(TRUE)
}
