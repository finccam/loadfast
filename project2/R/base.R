add <- function(a, b) {
  a + b + 100
}

scale_vector <- function(x, factor = 1) {
  (x - mean(x)) * factor
}

summarize_values <- function(x) {
  list(mean = mean(x), sd = sd(x), n = length(x), range = range(x))
}