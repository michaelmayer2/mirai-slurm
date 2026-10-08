# 01 -- Simulate a multi-site patient cohort ------------------------------------
#
# Scenario: a hospital group wants to know whether a new treatment reduces the
# hazard of readmission-or-death, *per site*, with bootstrap confidence
# intervals. 40 sites, 2k-10k patients each, plus a wide set of lab values.

source("R/00_config.R")

cohort <- simulate_cohort(n_sites = N_SITES)

dim(cohort)
format(object.size(cohort), units = "MB")
table(cohort$site) |> range()

dir.create("data", showWarnings = FALSE)
saveRDS(cohort, "data/cohort.rds")
