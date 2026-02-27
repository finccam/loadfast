# test_loadfast.R
# Run from the loadfast/ directory: Rscript test_loadfast.R
source("loadfast.R")
source("test_checks.R")

# ============================================================================
# Summary
# ============================================================================
cat("\n")
cat("Results:", passed, "passed,", failed, "failed\n")
if (failed > 0L) {
  cat("SOME TESTS FAILED\n")
  quit(status = 1L)
} else {
  cat("ALL TESTS PASSED\n")
}