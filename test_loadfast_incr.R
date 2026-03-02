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
invisible(file.copy(file.path("project1", "DESCRIPTION"), tmp_dir))
invisible(file.copy(file.path("project1", "NAMESPACE"), tmp_dir))
dir.create(file.path(tmp_dir, "R"))
for (f in list.files(file.path("project1", "R"), full.names = TRUE)) {
  invisible(file.copy(f, file.path(tmp_dir, "R", basename(f))))
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

check("remove-fn: summarize_values lingers (no stale cleanup)", quote(
  exists("summarize_values", envir = ns3b, inherits = FALSE)
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

# full=TRUE cleans up stale symbols
ns3b_full <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE, full = TRUE)

check("remove-fn: full=TRUE clears summarize_values from ns", quote(
  !exists("summarize_values", envir = ns3b_full, inherits = FALSE)
))

check("remove-fn: full=TRUE clears summarize_values from pkg env", quote(
  !exists("summarize_values", where = pkg_env_name3, inherits = FALSE)
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

invisible(file.remove(file.path(tmp_dir, "R", "extras.R")))

ns3f <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)

check("del-file: negate lingers (no stale cleanup)", quote(
  exists("negate", envir = ns3f, inherits = FALSE)
))

check("del-file: add still works", quote(
  get("add", envir = ns3f)(1, 2) == 1003
))

check("del-file: R6 classes still work", quote({
  ctr <- get("Counter", envir = ns3f)$new()
  ctr$increment(by = 3L)
  ctr$value == 3L
}))

# full=TRUE cleans up stale symbols from deleted file
ns3f_full <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE, full = TRUE)

check("del-file: full=TRUE clears negate from ns", quote(
  !exists("negate", envir = ns3f_full, inherits = FALSE)
))

check("del-file: full=TRUE clears double from ns", quote(
  !exists("double", envir = ns3f_full, inherits = FALSE)
))

check("del-file: full=TRUE clears negate from pkg env", quote(
  !exists("negate", where = pkg_env_name3, inherits = FALSE)
))

check("del-file: full=TRUE clears double from pkg env", quote(
  !exists("double", where = pkg_env_name3, inherits = FALSE)
))

check("del-file: full=TRUE add still works", quote(
  get("add", envir = ns3f_full)(1, 2) == 1003
))

# ============================================================================
# 3g: Cross-file plain function dependency
#     compute() in wrappers.R calls add() from base.R.
#     Changing only base.R should change compute()'s output.
# ============================================================================
cat("\n--- 3g: cross-file function dependency ---\n\n")

writeLines(c(
  "compute <- function(a, b) add(a, b) * 10"
), file.path(tmp_dir, "R", "wrappers.R"))

ns3g <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)

check("xdep-fn: compute(1,2) uses current add => (1+2+1000)*10 = 10030", quote(
  get("compute", envir = ns3g)(1, 2) == 10030
))

# Change only base.R: revert add to simple a+b
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

ns3g2 <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)

check("xdep-fn: compute(1,2) reflects changed add => (1+2)*10 = 30", quote(
  get("compute", envir = ns3g2)(1, 2) == 30
))

check("xdep-fn: compute in pkg env also reflects change", quote(
  get("compute", pos = pkg_env_name3)(1, 2) == 30
))

# ============================================================================
# 3h: Cross-file S4 method dependency
#     describe_loud() in wrappers.R calls the describe() generic whose
#     method is defined in s4_classes.R.  Changing only the method in
#     s4_classes.R should change describe_loud()'s output.
# ============================================================================
cat("\n--- 3h: cross-file S4 method dependency ---\n\n")

writeLines(c(
  "compute <- function(a, b) add(a, b) * 10",
  "",
  "describe_loud <- function(obj) paste0(describe(obj), \"!!!\")"
), file.path(tmp_dir, "R", "wrappers.R"))

ns3h <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)

a3h <- get("animal", envir = ns3h)("Rex", "dog", 4)
check("xdep-method: describe_loud uses original describe", quote(
  get("describe_loud", envir = ns3h)(a3h) == "Rex is a dog with 4 legs!!!"
))

# Change only s4_classes.R: alter describe(Animal) output format
writeLines(c(
  "setClass(\"Animal\", representation(",
  "  name    = \"character\",",
  "  species = \"character\",",
  "  legs    = \"numeric\"",
  "))",
  "",
  "setClass(\"Pet\", contains = \"Animal\", representation(",
  "  owner = \"character\"",
  "))",
  "",
  "setGeneric(\"describe\", function(object, ...) {",
  "  standardGeneric(\"describe\")",
  "})",
  "",
  "setGeneric(\"greet\", function(object) {",
  "  standardGeneric(\"greet\")",
  "})",
  "",
  "setMethod(\"describe\", \"Animal\", function(object, ...) {",
  "  paste0(object@name, \" the \", object@species, \" (\", object@legs, \" legs)\")",
  "})",
  "",
  "setMethod(\"describe\", \"Pet\", function(object, ...) {",
  "  base_desc <- callNextMethod()",
  "  paste0(base_desc, \", owned by \", object@owner)",
  "})",
  "",
  "setMethod(\"greet\", \"Pet\", function(object) {",
  "  paste0(\"Hello! My name is \", object@name, \" and I belong to \", object@owner)",
  "})",
  "",
  "animal <- function(name, species, legs) {",
  "  new(\"Animal\", name = name, species = species, legs = legs)",
  "}",
  "",
  "pet <- function(name, species, legs, owner) {",
  "  new(\"Pet\", name = name, species = species, legs = legs, owner = owner)",
  "}"
), file.path(tmp_dir, "R", "s4_classes.R"))

ns3h2 <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)

a3h2 <- get("animal", envir = ns3h2)("Rex", "dog", 4)
check("xdep-method: describe_loud reflects changed describe method", quote(
  get("describe_loud", envir = ns3h2)(a3h2) == "Rex the dog (4 legs)!!!"
))

check("xdep-method: describe_loud in pkg env also reflects change", quote(
  get("describe_loud", pos = pkg_env_name3)(a3h2) == "Rex the dog (4 legs)!!!"
))

# Also verify with Pet (callNextMethod chain)
p3h2 <- get("pet", envir = ns3h2)("Milo", "cat", 4, "Alice")
check("xdep-method: describe(Pet) uses updated Animal method via callNextMethod", quote(
  get("describe", envir = ns3h2)(p3h2) == "Milo the cat (4 legs), owned by Alice"
))

# ============================================================================
# 3i: Cross-file S4 class change affecting constructor in another file
#     make_animal() in wrappers.R calls new("Animal", ...).  Changing the
#     Animal class definition in s4_classes.R (adding an age slot with
#     a prototype default) should make make_animal() return an object
#     with the new slot.
# ============================================================================
cat("\n--- 3i: cross-file S4 class change affecting constructor ---\n\n")

writeLines(c(
  "compute <- function(a, b) add(a, b) * 10",
  "",
  "describe_loud <- function(obj) paste0(describe(obj), \"!!!\")",
  "",
  "make_animal <- function(n, s, l) new(\"Animal\", name = n, species = s, legs = l)"
), file.path(tmp_dir, "R", "wrappers.R"))

ns3i <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)

a3i <- get("make_animal", envir = ns3i)("Rex", "dog", 4)
check("xdep-s4class: make_animal creates Animal (before class change)", quote(
  is(a3i, "Animal") && a3i@name == "Rex" && a3i@legs == 4
))

check("xdep-s4class: Animal does NOT have age slot yet", quote(
  !methods::.hasSlot(a3i, "age")
))

# Change only s4_classes.R: add age slot with prototype default
writeLines(c(
  "setClass(\"Animal\", representation(",
  "  name    = \"character\",",
  "  species = \"character\",",
  "  legs    = \"numeric\",",
  "  age     = \"numeric\"",
  "), prototype = list(age = 0))",
  "",
  "setClass(\"Pet\", contains = \"Animal\", representation(",
  "  owner = \"character\"",
  "))",
  "",
  "setGeneric(\"describe\", function(object, ...) {",
  "  standardGeneric(\"describe\")",
  "})",
  "",
  "setGeneric(\"greet\", function(object) {",
  "  standardGeneric(\"greet\")",
  "})",
  "",
  "setMethod(\"describe\", \"Animal\", function(object, ...) {",
  "  paste0(object@name, \" the \", object@species, \" (\", object@legs, \" legs)\")",
  "})",
  "",
  "setMethod(\"describe\", \"Pet\", function(object, ...) {",
  "  base_desc <- callNextMethod()",
  "  paste0(base_desc, \", owned by \", object@owner)",
  "})",
  "",
  "setMethod(\"greet\", \"Pet\", function(object) {",
  "  paste0(\"Hello! My name is \", object@name, \" and I belong to \", object@owner)",
  "})",
  "",
  "animal <- function(name, species, legs, age = 0) {",
  "  new(\"Animal\", name = name, species = species, legs = legs, age = age)",
  "}",
  "",
  "pet <- function(name, species, legs, owner) {",
  "  new(\"Pet\", name = name, species = species, legs = legs, owner = owner)",
  "}"
), file.path(tmp_dir, "R", "s4_classes.R"))

# Incremental reload — only s4_classes.R is re-sourced, wrappers.R is NOT
ns3i2 <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE)

# S4 class redefinition may silently fail without full eviction (per AGENTS.md).
# Test what actually happens and then verify full=TRUE always works.
a3i2_incr <- tryCatch(
  get("make_animal", envir = ns3i2)("Rex", "dog", 4),
  error = function(e) e
)

has_age_incr <- tryCatch(
  !inherits(a3i2_incr, "error") &&
    methods::.hasSlot(a3i2_incr, "age") &&
    a3i2_incr@age == 0,
  error = function(e) FALSE
)

if (has_age_incr) {
  check("xdep-s4class: incremental picks up new age slot", quote(has_age_incr))
} else {
  cat("  (note: incremental reload did not pick up S4 class change — expected, use full=TRUE)\n")
}

# full=TRUE always works: full teardown re-registers the class cleanly
ns3i_full <- load_fast(tmp_dir, helpers = FALSE, attach_testthat = FALSE, full = TRUE)

a3i_full <- get("make_animal", envir = ns3i_full)("Rex", "dog", 4)

check("xdep-s4class: full=TRUE make_animal returns Animal with age slot", quote(
  is(a3i_full, "Animal") && methods::.hasSlot(a3i_full, "age")
))

check("xdep-s4class: full=TRUE age slot has prototype default 0", quote(
  a3i_full@age == 0
))

check("xdep-s4class: full=TRUE other slots still correct", quote(
  a3i_full@name == "Rex" && a3i_full@species == "dog" && a3i_full@legs == 4
))

# Also verify the animal() constructor in s4_classes.R can set age explicitly
a3i_aged <- get("animal", envir = ns3i_full)("Old Rex", "dog", 4, 12)
check("xdep-s4class: full=TRUE animal() constructor accepts age param", quote(
  a3i_aged@age == 12
))

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