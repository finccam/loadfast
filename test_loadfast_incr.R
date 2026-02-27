# test_loadfast_incr.R
# Run from the loadfast/ directory: Rscript test_loadfast_incr.R
source("loadfast_incr.R")
source("test_checks.R")

# ============================================================================
# STAGE 3: Incremental-specific tests using a temp copy of project1
# ============================================================================
cat("\n--- Stage 3: incremental reload tests (temp project) ---\n\n")

tmp_dir <- tempfile("loadfast_test_")
dir.create(tmp_dir)
on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)

# Deep-copy project1 into temp dir (only DESCRIPTION, NAMESPACE, R/)
file.copy(file.path("project1", "DESCRIPTION"), tmp_dir)
file.copy(file.path("project1", "NAMESPACE"), tmp_dir)
dir.create(file.path(tmp_dir, "R"))
for (f in list.files(file.path("project1", "R"), full.names = TRUE)) {
  file.copy(f, file.path(tmp_dir, "R", basename(f)))
}

# --- Initial full load of temp project ---
ns3 <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)
pkg_env_name3 <- "package:devpackage"

check("tmp: full load works", quote(
  is.environment(ns3) && isNamespace(ns3)
))

check("tmp: add(1,2) returns 3", quote(
  get("add", envir = ns3)(1, 2) == 3
))

check("tmp: summarize_values exists", quote(
  exists("summarize_values", envir = ns3, inherits = FALSE)
))

check("tmp: scale_vector exists", quote(
  exists("scale_vector", envir = ns3, inherits = FALSE)
))

# ============================================================================
# 3a: No change — second load should short-circuit
# ============================================================================
cat("\n--- 3a: no-change reload ---\n\n")

ns3a <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)

check("no-change: returns same ns_env", quote(
  identical(ns3a, ns3)
))

check("no-change: add still works", quote(
  get("add", envir = ns3a)(10, 20) == 30
))

# ============================================================================
# 3b: Remove a function from base.R
# ============================================================================
cat("\n--- 3b: remove summarize_values from base.R ---\n\n")

writeLines(c(
  "add <- function(a, b) {",
  "  a + b",
  "}",
  "",
  "scale_vector <- function(x, factor = 1) {",
  "  x * factor",
  "}"
), file.path(tmp_dir, "R", "base.R"))

ns3b <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)

check("remove-fn: summarize_values gone from namespace", quote(
  !exists("summarize_values", envir = ns3b, inherits = FALSE)
))

check("remove-fn: summarize_values gone from pkg env", quote(
  !exists("summarize_values", where = pkg_env_name3, inherits = FALSE)
))

check("remove-fn: add still works", quote(
  get("add", envir = ns3b)(1, 2) == 3
))

check("remove-fn: scale_vector still works", quote(
  identical(get("scale_vector", envir = ns3b)(1:3, factor = 2), c(2, 4, 6))
))

check("remove-fn: R6 classes unaffected", quote(
  exists("Logger", envir = ns3b, inherits = FALSE) &&
  exists("Counter", envir = ns3b, inherits = FALSE)
))

# ============================================================================
# 3c: Add a new function to base.R
# ============================================================================
cat("\n--- 3c: add multiply() to base.R ---\n\n")

writeLines(c(
  "add <- function(a, b) {",
  "  a + b",
  "}",
  "",
  "scale_vector <- function(x, factor = 1) {",
  "  x * factor",
  "}",
  "",
  "multiply <- function(a, b) {",
  "  a * b",
  "}"
), file.path(tmp_dir, "R", "base.R"))

ns3c <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)

check("add-fn: multiply exists in namespace", quote(
  exists("multiply", envir = ns3c, inherits = FALSE)
))

check("add-fn: multiply(3,4) returns 12", quote(
  get("multiply", envir = ns3c)(3, 4) == 12
))

check("add-fn: multiply visible from pkg env", quote(
  exists("multiply", where = pkg_env_name3, inherits = FALSE)
))

check("add-fn: summarize_values still gone", quote(
  !exists("summarize_values", envir = ns3c, inherits = FALSE)
))

check("add-fn: add still works", quote(
  get("add", envir = ns3c)(5, 6) == 11
))

# ============================================================================
# 3d: Modify a function (change behavior, same name)
# ============================================================================
cat("\n--- 3d: modify add() behavior ---\n\n")

writeLines(c(
  "add <- function(a, b) {",
  "  a + b + 1000",
  "}",
  "",
  "scale_vector <- function(x, factor = 1) {",
  "  x * factor",
  "}",
  "",
  "multiply <- function(a, b) {",
  "  a * b",
  "}"
), file.path(tmp_dir, "R", "base.R"))

ns3d <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)

check("modify-fn: add(1,2) now returns 1003", quote(
  get("add", envir = ns3d)(1, 2) == 1003
))

check("modify-fn: add updated in pkg env too", quote(
  get("add", pos = pkg_env_name3)(1, 2) == 1003
))

check("modify-fn: multiply still works", quote(
  get("multiply", envir = ns3d)(3, 4) == 12
))

# ============================================================================
# 3e: Add a new R file
# ============================================================================
cat("\n--- 3e: add new file extras.R ---\n\n")

writeLines(c(
  "negate <- function(x) -x",
  "",
  "double <- function(x) x * 2"
), file.path(tmp_dir, "R", "extras.R"))

ns3e <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)

check("new-file: negate exists", quote(
  exists("negate", envir = ns3e, inherits = FALSE)
))

check("new-file: negate(5) returns -5", quote(
  get("negate", envir = ns3e)(5) == -5
))

check("new-file: double exists in pkg env", quote(
  exists("double", where = pkg_env_name3, inherits = FALSE)
))

check("new-file: double(7) returns 14", quote(
  get("double", pos = pkg_env_name3)(7) == 14
))

check("new-file: existing functions unaffected", quote(
  get("add", envir = ns3e)(1, 2) == 1003
))

# ============================================================================
# 3f: Delete an R file entirely
# ============================================================================
cat("\n--- 3f: delete extras.R ---\n\n")

file.remove(file.path(tmp_dir, "R", "extras.R"))

ns3f <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)

check("del-file: negate gone from namespace", quote(
  !exists("negate", envir = ns3f, inherits = FALSE)
))

check("del-file: negate gone from pkg env", quote(
  !exists("negate", where = pkg_env_name3, inherits = FALSE)
))

check("del-file: double gone from namespace", quote(
  !exists("double", envir = ns3f, inherits = FALSE)
))

check("del-file: double gone from pkg env", quote(
  !exists("double", where = pkg_env_name3, inherits = FALSE)
))

check("del-file: add still works", quote(
  get("add", envir = ns3f)(1, 2) == 1003
))

check("del-file: R6 classes still work", quote({
  ctr <- get("Counter", envir = ns3f)$new()
  ctr$increment(by = 3L)
  ctr$value == 3L
}))

# ============================================================================
# Summary (inherited counters from test_checks.R)
# ============================================================================
cat("\n")
cat("Results:", passed, "passed,", failed, "failed\n")
if (failed > 0L) {
  cat("SOME TESTS FAILED\n")
  quit(status = 1L)
} else {
  cat("ALL TESTS PASSED\n")
}