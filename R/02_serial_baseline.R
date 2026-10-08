# 02 -- How long would this take on one core? -----------------------------------

source("R/00_config.R")
cohort    <- readRDS("data/cohort.rds")
site_list <- split(cohort, cohort$site)

# One site, a reduced number of resamples ...
one_site <- site_list[[1]]
nrow(one_site)

t_small <- system.time(
  res <- bootstrap_site(one_site, n_boot = N_BOOT_PROFILE)
)[["elapsed"]]
res

# ... extrapolate to the production run: time scales ~linearly in n_boot
# and in the number of patients per site.
sec_per_boot_per_patient <- t_small / (N_BOOT_PROFILE * nrow(one_site))
serial_estimate <- sec_per_boot_per_patient * N_BOOT * nrow(cohort)

cat(sprintf("Estimated serial runtime: %.0f minutes (%.1f hours)\n",
            serial_estimate / 60, serial_estimate / 3600))

# The naive "fix" -- everything in parallel, as many workers as possible:
#
#   daemons(200, url = host_url(), remote = cluster_config())
#
# ... without knowing how much memory, how many CPUs, or how much time each
# worker needs. That is what the rest of the workshop is about.
