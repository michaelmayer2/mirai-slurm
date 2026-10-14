# 06 -- Plot speedup and parallel efficiency -------------------------------------

source("R/00_config.R")
library(ggplot2)

scaling <- read.csv("results/scaling.csv")
cohort  <- readRDS("data/cohort.rds")

# For contrast: with one site per task (40 unequal tasks) the run could never
# be shorter than the largest site. Work ~ patients per site. Chunked tasks
# (CHUNK_SIZE resamples) push this limit far beyond the plotted range.
sizes     <- as.numeric(table(cohort$site))
max_speed <- sum(sizes) / max(sizes)

# Amdahl's law fit: T(n) = T1 * (s + (1 - s) / n), s = serial fraction
t1  <- scaling$compute_s[scaling$daemons == 1]
fit <- nls(compute_s ~ t1 * (s + (1 - s) / daemons), data = scaling,
           start = list(s = 0.05), lower = list(s = 0), upper = list(s = 1),
           algorithm = "port")
s_hat <- coef(fit)[["s"]]

grid <- data.frame(daemons = 2^seq(0, log2(max(scaling$daemons)), length.out = 50))
grid$amdahl <- 1 / (s_hat + (1 - s_hat) / grid$daemons)

p_speedup <- ggplot(scaling, aes(daemons, speedup)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", colour = "grey50") +
  geom_hline(yintercept = max_speed, linetype = "dotted", colour = "firebrick") +
  geom_line(data = grid, aes(y = amdahl), colour = "steelblue", alpha = 0.6) +
  geom_point(size = 3) + geom_line() +
  annotate("text", x = 1, y = max_speed, vjust = -0.5, hjust = 0, size = 3,
           label = "limit with 1 site per task", colour = "firebrick") +
  scale_x_continuous(trans = "log2", breaks = scaling$daemons) +
  scale_y_continuous(trans = "log2") +
  labs(title = "Speedup vs. number of daemons",
       subtitle = sprintf("dashed: ideal  |  blue: Amdahl fit, serial fraction = %.1f%%",
                          100 * s_hat),
       x = "daemons", y = "speedup") +
  theme_minimal()

p_eff <- ggplot(scaling, aes(daemons, efficiency)) +
  geom_hline(yintercept = 1, linetype = "dashed", colour = "grey50") +
  geom_point(size = 3) + geom_line() +
  scale_x_continuous(trans = "log2", breaks = scaling$daemons) +
  scale_y_continuous(labels = scales::percent, limits = c(0, 1.1)) +
  labs(title = "Parallel efficiency = speedup / daemons",
       subtitle = "below ~70%: extra daemons mostly sit idle in the allocation",
       x = "daemons", y = NULL) +
  theme_minimal()

p_speedup
p_eff

ggsave("results/scaling_speedup.png", p_speedup, width = 7, height = 4.5, dpi = 150)
ggsave("results/scaling_efficiency.png", p_eff, width = 7, height = 4.5, dpi = 150)
