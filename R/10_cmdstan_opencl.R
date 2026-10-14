# 10 -- Bayesian GLMs on a GPU: CmdStan with OpenCL --------------------------------
#
# The same Bayesian logistic regression (stan/logit_glm.stan, built on
# bernoulli_logit_glm(), one of the Stan functions with an OpenCL version)
# on one CPU core and on the GPU:
#   sbatch slurm/bench_stan_cpu.sbatch   # m7a node
#   sbatch slurm/bench_stan_gpu.sbatch   # g4dn node: CPU core + OpenCL on the T4
# Appends to results/gpu_benchmarks.csv (same columns as 09_).

source("R/00_config.R")
library(cmdstanr)

has_gpu  <- nzchar(Sys.which("nvidia-smi")) && system("nvidia-smi -L > /dev/null 2>&1") == 0
cores    <- parallelly::availableCores()
hardware <- if (has_gpu) sprintf("g4dn: %d vCPU + T4", cores) else sprintf("m7a: %d vCPU", cores)
STAN_N   <- as.integer(Sys.getenv("STAN_N", 5e5))
# Run a subset, e.g. STAN_CASES=brms STAN_BACKENDS=opencl
STAN_CASES    <- strsplit(Sys.getenv("STAN_CASES", "cmdstan,brms"), ",")[[1]]
STAN_BACKENDS <- intersect(strsplit(Sys.getenv("STAN_BACKENDS", "cpu,opencl"), ",")[[1]],
                           c("cpu", if (has_gpu) "opencl"))

# Same kind of data as 09_, standardised (helps the sampler; same model either way)
big <- simulate_cohort(n_sites = ceiling(STAN_N / 4000), seed = 2026)
stopifnot(nrow(big) >= STAN_N)
big <- big[seq_len(STAN_N), ]
x <- as.matrix(cbind(age = big$age, male = big$sex == "M", comorbidity = big$comorbidity,
                     new = big$treatment == "new", big[grep("^lab_", names(big))]))
storage.mode(x) <- "double"
x <- scale(x)
y <- big$event
stan_data <- list(N = nrow(x), K = ncol(x), X = unclass(x), y = y)

b_glm <- coef(glm.fit(cbind(1, x), y, family = binomial()))   # reference
# Each result goes to the CSV as soon as it exists: a later failure can't lose it.
csv <- "results/gpu_benchmarks.csv"
record <- function(case, backend, seconds, check = NA_real_, note = "") {
  message(sprintf("%-28s %-26s %8.1fs  check=%s  %s", case, backend, seconds,
                  format(check, digits = 3), note))
  row <- data.frame(hardware = hardware, case = case, backend = backend, n = nrow(x),
                    seconds = seconds, check = check, note = note)
  write.table(row, csv, sep = ",", row.names = FALSE,
              col.names = !file.exists(csv), append = file.exists(csv))
}

# 1. CmdStan: CPU (1 core) vs. OpenCL -------------------------------------------------
for (backend in if ("cmdstan" %in% STAN_CASES) STAN_BACKENDS) {
  opencl <- backend == "opencl"
  model  <- cmdstan_model("stan/logit_glm.stan",
                          cpp_options = if (opencl) list(stan_opencl = TRUE) else list(),
                          exe_file = sprintf("stan/logit_glm_%s", backend))
  fit <- model$sample(data = stan_data, chains = 1, iter_warmup = 500, iter_sampling = 500,
                      seed = 1, refresh = 0, show_messages = FALSE,
                      opencl_ids = if (opencl) c(0, 0))
  seconds <- fit$time()$total                                   # warmup + sampling
  post    <- colMeans(fit$draws(c("alpha", "beta"), format = "draws_matrix"))
  ess     <- posterior::ess_bulk(fit$draws("beta[4]"))          # treatment effect
  record("Bayesian logistic GLM", sprintf("CmdStan %s", if (opencl) "OpenCL (T4)" else "1 CPU core"),
         seconds, check = max(abs(post - b_glm)),
         note = sprintf("check = max |posterior mean - glm|; ESS/s %.1f", ess / seconds))
}

# 2. brms: does it generate the GPU-capable GLM function? -----------------------------
if ("brms" %in% STAN_CASES && requireNamespace("brms", quietly = TRUE)) {
  df <- data.frame(unclass(x), event = y)
  code <- brms::stancode(event ~ ., data = df[1:1000, ], family = brms::bernoulli())
  uses_glm <- grepl("bernoulli_logit_glm", code)
  message("brms generates bernoulli_logit_glm(): ", uses_glm)
  if (uses_glm) {
    for (backend in STAN_BACKENDS) {
      opencl <- backend == "opencl"
      # Same Stan code as the CPU fit: without force_recompile the cached CPU
      # binary is reused and the OpenCL chain fails ("Unable to retrieve the metadata").
      fit <- brms::brm(event ~ ., data = df, family = brms::bernoulli(), backend = "cmdstanr",
                       chains = 1, warmup = 500, iter = 1000, seed = 1, refresh = 0,
                       opencl = if (opencl) brms::opencl(c(0, 0)),
                       stan_model_args = if (opencl) list(force_recompile = TRUE) else list())
      seconds <- sum(rstan::get_elapsed_time(fit$fit))         # warmup + sampling, no compile
      post <- brms::fixef(fit)[, "Estimate"]
      record("Bayesian logistic GLM", sprintf("brms %s", if (opencl) "OpenCL (T4)" else "1 CPU core"),
             seconds, check = max(abs(post - b_glm)),
             note = "check = max |posterior mean - glm|; brms default priors")
    }
  }
}

tail(read.csv(csv), 6)
