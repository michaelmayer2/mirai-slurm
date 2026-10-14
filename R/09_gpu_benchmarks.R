# 09 -- What does a GPU buy a frequentist shop? ----------------------------------
#
# The same cases on whichever hardware this job runs on:
#   sbatch slurm/bench_cpu.sbatch   # m7a node, 4 vCPU
#   sbatch slurm/bench_gpu.sbatch   # g4dn node, 2 vCPU + 1 NVIDIA T4
# Each run appends to results/gpu_benchmarks.csv. GPU packages (xgboost GPU
# build, torch cu128) live in ~/R/gpu-library -- see slurm/install_gpu_packages.sbatch.

source("R/00_config.R")

has_gpu  <- nzchar(Sys.which("nvidia-smi")) &&
  system("nvidia-smi -L > /dev/null 2>&1") == 0
cores    <- parallelly::availableCores()
hardware <- if (has_gpu) sprintf("g4dn: %d vCPU + T4", cores) else sprintf("m7a: %d vCPU", cores)
BENCH_N  <- as.integer(Sys.getenv("BENCH_N", 2e6))     # rows in the "large" data set

# A larger cohort with the same structure: 2M patients, 50 lab values
set.seed(1)
n_sites <- ceiling(BENCH_N / 4000)                     # sites have 2,000-10,000 patients
big <- simulate_cohort(n_sites = n_sites, seed = 2026)
stopifnot(nrow(big) >= BENCH_N)
big <- big[seq_len(BENCH_N), ]
x <- as.matrix(cbind(age = big$age, male = big$sex == "M", comorbidity = big$comorbidity,
                     new = big$treatment == "new", big[grep("^lab_", names(big))]))
storage.mode(x) <- "double"
y <- big$event
test <- seq_len(nrow(x)) %% 5 == 0                     # 20% holdout

auc <- function(score, label) {                        # Mann-Whitney AUC
  r <- rank(score); n1 <- as.numeric(sum(label == 1)); n0 <- as.numeric(sum(label == 0))
  (sum(r[label == 1]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}
results <- list()
record <- function(case, backend, seconds, check = NA_real_, note = "") {
  message(sprintf("%-28s %-22s %8.2fs  check=%s  %s", case, backend, seconds,
                  format(check, digits = 4), note))
  results[[length(results) + 1]] <<- data.frame(
    hardware = hardware, case = case, backend = backend, n = nrow(x),
    seconds = seconds, check = check, note = note)
}
timed <- function(expr) {
  t <- system.time(value <- force(expr))[["elapsed"]]
  list(value = value, seconds = t)
}

# 1. xgboost: the classic GPU win -------------------------------------------------
library(xgboost)
dtrain <- xgb.DMatrix(x[!test, ], label = y[!test])
params <- list(objective = "binary:logistic", tree_method = "hist",
               max_depth = 6, eta = 0.1, nthread = cores)
devices <- c("cpu", if (has_gpu) "cuda")
for (dev in devices) {
  fit <- timed(xgb.train(params = c(params, device = dev), data = dtrain, nrounds = 200))
  pred <- predict(fit$value, xgb.DMatrix(x[test, ]))
  record("xgboost, 200 trees", sprintf("xgboost %s", dev), fit$seconds,
         check = auc(pred, y[test]), note = "check = holdout AUC")
}

# 2. the same through tidymodels: one engine argument ------------------------------
library(parsnip)
df_train <- data.frame(x[!test, ], event = factor(y[!test]))
for (dev in devices) {
  spec <- boost_tree(trees = 200, tree_depth = 6, learn_rate = 0.1) |>
    set_mode("classification") |>
    set_engine("xgboost", device = dev, tree_method = "hist", nthread = cores)
  fit <- timed(fit(spec, event ~ ., data = df_train))
  pred <- predict(fit$value, data.frame(x[test, ]), type = "prob")[[".pred_1"]]
  record("tidymodels boost_tree()", sprintf("parsnip + xgboost %s", dev), fit$seconds,
         check = auc(pred, y[test]), note = "check = holdout AUC")
}

# 3. Large logistic GLM: glm() vs IRLS in torch -------------------------------------
fit_glm <- timed(glm.fit(cbind(1, x), y, family = binomial()))
b_glm   <- coef(fit_glm$value)
record("logistic GLM (55 coefs)", "glm.fit() (CPU)", fit_glm$seconds,
       check = 0, note = "check = max |coef - glm|")

library(torch)
irls_torch <- function(X, y, device, dtype = torch_float64(), iter = 25, tol = 1e-8) {
  X <- torch_tensor(X, dtype = dtype, device = device)
  y <- torch_tensor(y, dtype = dtype, device = device)
  b <- torch_zeros(X$size(2), dtype = dtype, device = device)
  for (i in seq_len(iter)) {
    mu <- torch_sigmoid(torch_mv(X, b))
    w  <- mu * (1 - mu)
    step <- linalg_solve(torch_mm(X$t(), X * w$unsqueeze(2)), torch_mv(X$t(), y - mu))
    b  <- b + step
    if (as.numeric(step$abs()$max()$cpu()) < tol) break
  }
  as.numeric(b$cpu())
}
for (dev in c("cpu", if (has_gpu) "cuda")) {
  fit <- timed(irls_torch(cbind(1, x), y, dev))
  record("logistic GLM (55 coefs)", sprintf("torch IRLS %s (fp64)", dev), fit$seconds,
         check = max(abs(fit$value - b_glm)), note = "check = max |coef - glm|")
}
# GPUs like the T4 are built for single precision; fp64 runs at a fraction of
# the speed. fp32 is fast -- but how far are the coefficients from glm()?
if (has_gpu) {
  fit <- timed(irls_torch(cbind(1, x), y, "cuda", dtype = torch_float32(), tol = 1e-5))
  record("logistic GLM (55 coefs)", "torch IRLS cuda (fp32)", fit$seconds,
         check = max(abs(fit$value - b_glm)), note = "check = max |coef - glm|")
}

# 3b. The same GLM through tidymodels on the GPU: cuda.ml (RAPIDS cuML) ------------
# Note: cuML's logistic regression is L2-penalised by default, so compare AUC,
# not coefficients.
if (has_gpu && requireNamespace("cuda.ml", quietly = TRUE)) {
  fit <- timed(logistic_reg() |> set_engine("cuda.ml") |> fit(event ~ ., data = df_train))
  pred <- predict(fit$value, data.frame(x[test, ]), type = "prob")[[".pred_1"]]
  record("logistic GLM (55 coefs)", "parsnip + cuda.ml", fit$seconds,
         check = auc(pred, y[test]), note = "check = holdout AUC")
  b_auc <- auc(cbind(1, x[test, ]) %*% b_glm, y[test])
  record("logistic GLM (55 coefs)", "glm.fit() AUC (reference)", NA_real_, check = b_auc,
         note = "check = holdout AUC")
}

# 4. Dense linear algebra: what GPUs are built for ----------------------------------
m <- 8192
for (dev in c("cpu", if (has_gpu) "cuda")) {
  a <- torch_randn(m, m, device = dev)          # float32
  invisible(torch_mm(a, a))                     # warm-up
  if (dev == "cuda") cuda_synchronize()
  fit <- timed({ r <- torch_mm(a, a); if (dev == "cuda") cuda_synchronize(); r })
  record("8192 x 8192 matmul (fp32)", sprintf("torch %s", dev), fit$seconds,
         note = sprintf("%.0f GFLOP/s", 2 * m^3 / fit$seconds / 1e9))
}

# 5. Bread and butter without a GPU path ---------------------------------------------
# survival::coxph and lme4 run on the CPU only. Per model they are fast; the
# win comes from running many of them in parallel (bootstrap, sites, ...).
one_site <- big[big$site == big$site[1], ]
fit <- timed(survival::coxph(survival::Surv(time, event) ~ treatment + age + sex + comorbidity,
                             data = one_site))
record("coxph, one site", "survival (CPU only)", fit$seconds,
       note = sprintf("%d patients", nrow(one_site)))
fit <- timed(survival::coxph(survival::Surv(time, event) ~ treatment + age + sex + comorbidity +
                               survival::strata(site), data = big))
record("coxph, all patients, strata(site)", "survival (CPU only)", fit$seconds,
       note = sprintf("%d patients", nrow(big)))
fit <- timed(lme4::glmer(event ~ treatment + age + sex + comorbidity + (1 | site),
                         data = big[seq_len(5e5), ], family = binomial(), nAGQ = 0))
record("glmer, 500k rows, (1 | site)", "lme4 (CPU only)", fit$seconds,
       note = sprintf("%d sites, nAGQ = 0", length(unique(big$site[seq_len(5e5)]))))

out <- do.call(rbind, results)
out
dir.create("results", showWarnings = FALSE)
csv <- "results/gpu_benchmarks.csv"
write.table(out, csv, sep = ",", row.names = FALSE,
            col.names = !file.exists(csv), append = file.exists(csv))
