# 02 -- It worked with 200 resamples. What about 5,000? ---------------------------

source("R/00_config.R")
cohort    <- readRDS("data/cohort.rds")
site_list <- split(cohort, cohort$site)

# The test run: one site, a handful of resamples -- quick, looks fine.
one_site <- site_list[[1]]
nrow(one_site)

t_test <- system.time(
  res <- bootstrap_site(one_site, n_boot = N_BOOT_TEST)
)[["elapsed"]]
res
cat(sprintf("Test run: %d resamples of one site (%d patients): %.1f s\n",
            N_BOOT_TEST, nrow(one_site), t_test))

# The real analysis: N_BOOT resamples for every site. Time scales ~linearly
# in n_boot and in the number of patients per site.
sec_per_boot_per_patient <- t_test / (N_BOOT_TEST * nrow(one_site))
serial_estimate <- sec_per_boot_per_patient * N_BOOT * nrow(cohort)

cat(sprintf("Production: %d resamples x %d sites: ~%.0f minutes (%.1f hours) on one core\n",
            N_BOOT, length(site_list), serial_estimate / 60, serial_estimate / 3600))

# Every resample is independent. One task = CHUNK_SIZE resamples of one site:
cat(sprintf("-> %d tasks of %d resamples each\n",
            length(site_list) * ceiling(N_BOOT / CHUNK_SIZE), CHUNK_SIZE))

# The naive "fix" -- everything in parallel, as many workers as possible:
#
#   daemons(200, url = host_url(), remote = cluster_config())
#
# ... without knowing how much memory, how many CPUs, or how much time each
# worker needs. That is what the rest of the workshop is about.
