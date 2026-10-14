// Bayesian logistic regression. bernoulli_logit_glm() is one of the Stan
// functions with an OpenCL (GPU) implementation; compiled with
// cpp_options = list(stan_opencl = TRUE) it runs on the GPU.
data {
  int<lower=0> N;
  int<lower=1> K;
  matrix[N, K] X;
  array[N] int<lower=0, upper=1> y;
}
parameters {
  real alpha;
  vector[K] beta;
}
model {
  alpha ~ normal(0, 5);
  beta ~ normal(0, 2.5);
  y ~ bernoulli_logit_glm(X, alpha, beta);
}
