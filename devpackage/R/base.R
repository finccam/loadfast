add <- function(a, b) {
  a + b
}

scale_vector <- function(x, factor = 1) {
  x * factor
}

summarize_values <- function(x) {
  list(mean = mean(x), sd = sd(x), n = length(x))
}

mutate_dt <- function(x, times = 2L) {
  dt <- as.data.table(list(val = x))
  dt[, scaled := val * times]
  dt
}