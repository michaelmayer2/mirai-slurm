# 03 -- With great power comes great responsibility ------------------------------
#
# Before asking SLURM for N workers, measure what ONE worker needs.
# We run a single task in a single local mirai daemon -- the exact code path
# that will later run on the cluster -- and watch it with syrup.

source("R/00_config.R")
library(ggplot2)

# A threaded BLAS (e.g. openblas-pthread) uses every core of the node for the
# small matrices in coxph() -- ~350% CPU for no speed-up. Profile the task the
# way the sbatch script will run it: one BLAS thread per allocated CPU.
Sys.setenv(OPENBLAS_NUM_THREADS = 1, OMP_NUM_THREADS = 1)

cohort    <- readRDS("data/cohort.rds")
site_list <- split(cohort, cohort$site)

# Profile the *largest* task, not a typical one: the memory request must fit
# the worst case or SLURM's OOM killer will find it for you.
sizes        <- vapply(site_list, nrow, integer(1))
largest_site <- site_list[[which.max(sizes)]]
sizes[which.max(sizes)]

plot_profile <- function(prof, title) {
  prof$pct_cpu[is.na(prof$pct_cpu)] <- 0
  total <- aggregate(cbind(pct_cpu, rss_mb) ~ id + elapsed, data = prof, FUN = sum)
  total$pid  <- 0L
  total$role <- "total (what SLURM sees)"
  prof <- rbind(prof[names(total)], total)
  long <- rbind(
    data.frame(prof[c("elapsed", "pid", "role")], metric = "CPU (%)",     value = prof$pct_cpu),
    data.frame(prof[c("elapsed", "pid", "role")], metric = "Memory (MB)", value = prof$rss_mb)
  )
  ggplot(long, aes(elapsed, value, group = pid, colour = role, linewidth = role)) +
    geom_line() +
    facet_wrap(~metric, ncol = 1, scales = "free_y") +
    expand_limits(y = 0) +     # start at 0: otherwise small wiggles look dramatic
    scale_colour_manual(values = c("daemon" = "steelblue", "forked child" = "grey60",
                                   "total (what SLURM sees)" = "black")) +
    scale_linewidth_manual(values = c("daemon" = 0.6, "forked child" = 0.4,
                                      "total (what SLURM sees)" = 1.1)) +
    labs(title = title, x = "seconds", y = NULL, colour = NULL, linewidth = NULL) +
    theme_minimal() +
    theme(legend.position = "bottom")
}

# Memory of several profiles on one, shared axis -- the only honest way to
# compare them (separate plots each get their own y range).
plot_memory_compare <- function(profs, title) {
  total <- do.call(rbind, lapply(names(profs), function(nm) {
    m <- aggregate(rss_mb ~ id + elapsed, data = profs[[nm]], FUN = sum)
    m$run <- nm
    m
  }))
  peaks <- do.call(rbind, lapply(split(total, total$run), function(d) d[nrow(d), ]))
  peaks$label <- sprintf("peak %.0f MB", tapply(total$rss_mb, total$run, max)[peaks$run])
  ggplot(total, aes(elapsed, rss_mb, colour = run)) +
    geom_line(linewidth = 1.1) +
    geom_text(data = peaks, aes(label = label), hjust = 1, vjust = -0.6,
              show.legend = FALSE) +
    expand_limits(y = 0) +
    scale_y_continuous(expand = expansion(mult = c(0.02, 0.1))) +   # room for labels
    scale_colour_manual(values = c("steelblue", "firebrick")) +
    labs(title = title, x = "seconds", y = "Memory (MB)", colour = NULL) +
    theme_minimal() +
    theme(legend.position = "bottom")
}

# 1. The well-behaved task -------------------------------------------------------
# Exactly what will run on the cluster: one chunk of CHUNK_SIZE resamples of the
# largest site, in a daemon that holds the shared data (as after everywhere()).
# The task size does not depend on N_BOOT, so this one profile is valid for any n_boot.
prof_good <- profile_task(bootstrap_chunk, site = largest_site$site[1], n_boot = CHUNK_SIZE,
                          helpers = list(site_list = site_list, bootstrap_site = bootstrap_site))
summarise_profile(prof_good)
plot_profile(prof_good, "bootstrap_chunk(): one task, one daemon")

# 2. Gotcha: memory that grows with the work -------------------------------------
# keep_fits = TRUE keeps every coxph object (with model matrix) "just in case".
# Compared at N_BOOT_PROFILE resamples in one call, with and without keep_fits.
prof_lean <- profile_task(bootstrap_site, site_df = largest_site, n_boot = N_BOOT_PROFILE)
prof_fits <- profile_task(bootstrap_site, site_df = largest_site,
                          n_boot = N_BOOT_PROFILE, keep_fits = TRUE)
summarise_profile(prof_fits)
fits_vs_good <- list("keep_fits = FALSE" = prof_lean, "keep_fits = TRUE" = prof_fits)
plot_memory_compare(fits_vs_good, "Same task, same n_boot: memory with and without keep_fits")
# -> memory now grows with the resamples *per task*. Chunks bound it, but the
#    same code with 5,000 resamples in one task would need ~8 GB.
#    Fix the code (return only what you need), don't just ask for more RAM.

# 3. Gotcha: hidden parallelism inside the task ----------------------------------
# A colleague's function "helpfully" parallelises internally with detectCores().
# On a SLURM node detectCores() reports ALL cores of the node, not your
# allocation -> 8 daemons x 64 forks on a 64-core node. (In a 1-CPU job:
# detectCores() = 4 on our 4-core nodes, parallelly::availableCores() = 1.)
# This is the anti-pattern -- never size parallelism with detectCores().
prof_nested <- profile_task(bootstrap_site, site_df = largest_site,
                            n_boot = N_BOOT_PROFILE * 4,
                            n_cores = parallel::detectCores())
summarise_profile(prof_nested)
plot_profile(prof_nested, "nested mclapply(): one task, many processes")
# -> CPU % far above 100 = the task needs (or steals) more than one core.
#    Either request --cpus-per-task accordingly and use
#    parallelly::availableCores() (SLURM allocation, cgroups, affinity),
#    or -- better for embarrassingly parallel work -- keep tasks single-threaded
#    and let mirai do the parallelism.
# -> Note: RSS of forked children is partly shared (copy-on-write), so summing
#    it over-counts. syrup gives you the coarse picture, not exact accounting.

# 4. Gotcha: shipping more data than the task needs ------------------------------
# Passing the whole cohort to every task and filtering inside:
naive_task <- function(cohort, site_id, n_boot) {
  bootstrap_site(cohort[cohort$site == site_id, ], n_boot = n_boot)
}
prof_naive <- profile_task(naive_task, cohort = cohort,
                           site_id = largest_site$site[1], n_boot = N_BOOT_PROFILE,
                           helpers = list(bootstrap_site = bootstrap_site))
summarise_profile(prof_naive)

c(whole_cohort = length(serialize(cohort, NULL)),
  one_site     = length(serialize(largest_site, NULL))) / 1e6   # MB per task
# -> multiplied by every task, sent over the network and held in every daemon.
#    split() first, ship only what each task needs.

# 5. From measurements to a resource request -------------------------------------
p <- summarise_profile(prof_good)
p

# Time per resample per patient, from the largest chunk. Total work for the
# production run = rate x N_BOOT x all patients, shared by N_DAEMONS daemons.
rate    <- p$wall_s / (CHUNK_SIZE * nrow(largest_site))
total_s <- rate * N_BOOT * sum(sizes)

resources <- list(
  task_s = p$wall_s,               # the largest chunk
  rate   = rate,
  cpus   = max(1L, as.integer(round(p$mean_cpu_pct / 100))),
  # 1.5x headroom on the peak, rounded up to 256 MB
  mem_mb = as.integer(ceiling(p$peak_rss_mb * 1.5 / 256) * 256),
  # 2x headroom for slower nodes + 5 min for start-up
  time_s = ceiling(total_s / N_DAEMONS * 2 + 300)
)
resources$time <- slurm_time(resources$time_s)
str(resources)

# This is what each of the N_DAEMONS sbatch jobs will ask for:
cat(slurm_options(resources, partition = SLURM_PARTITION, account = SLURM_ACCOUNT,
                  extra = SLURM_EXTRA), "\n")

dir.create("results", showWarnings = FALSE)
saveRDS(resources, "results/resources.rds")
plots <- list(
  good   = plot_profile(prof_good, "bootstrap_chunk(): one task, one daemon"),
  fits   = plot_memory_compare(fits_vs_good,
                               "Same task, same n_boot: memory with and without keep_fits"),
  nested = plot_profile(prof_nested, "nested mclapply(): one task, many processes"),
  naive  = plot_profile(prof_naive, "whole cohort shipped to the task")
)
for (nm in names(plots)) {
  ggsave(sprintf("results/profile_%s.png", nm), plots[[nm]], width = 7, height = 4.5, dpi = 150)
}
saveRDS(list(good = prof_good, lean = prof_lean, fits = prof_fits, nested = prof_nested,
             naive = prof_naive), "results/profiles.rds")
