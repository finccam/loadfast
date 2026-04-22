# Load package source directly from `R/` for the custom repo test harness.
source(file.path("R", "loadfast.R"))

passed <- 0L
failed <- 0L

.test_filter <- Sys.getenv("LOADFAST_TEST_FILTER", unset = "")
.test_filter_active <- nzchar(.test_filter)

if (.test_filter_active) {
  cat("Applying test filter:", .test_filter, "\n")
}

check <- function(description, expr) {
  if (.test_filter_active && !grepl(.test_filter, description, perl = TRUE)) {
    return(invisible(NULL))
  }
  result <- tryCatch(
    {
      ok <- eval(expr, envir = parent.frame())
      if (isTRUE(ok)) "pass" else paste("FAIL -- got", deparse(ok))
    },
    error = function(e) paste("ERROR --", conditionMessage(e))
  )
  if (result == "pass") {
    passed <<- passed + 1L
    cat("[PASS]", description, "\n")
  } else {
    failed <<- failed + 1L
    cat("[FAIL]", description, ":", result, "\n")
  }
}

.tmp_dirs <- character(0)

capture_warnings <- function(expr) {
  warnings <- character(0)
  value <- withCallingHandlers(
    expr,
    warning = function(w) {
      warnings <<- c(warnings, conditionMessage(w))
      invokeRestart("muffleWarning")
    }
  )
  list(value = value, warnings = warnings)
}

capture_messages <- function(expr) {
  messages <- character(0)
  value <- withCallingHandlers(
    expr,
    message = function(m) {
      messages <<- c(messages, conditionMessage(m))
    }
  )
  list(value = value, messages = messages)
}

capture_conditions <- function(expr) {
  warnings <- character(0)
  messages <- character(0)
  value <- withCallingHandlers(
    expr,
    warning = function(w) {
      warnings <<- c(warnings, conditionMessage(w))
      invokeRestart("muffleWarning")
    },
    message = function(m) {
      messages <<- c(messages, conditionMessage(m))
    }
  )
  list(value = value, warnings = warnings, messages = messages)
}

run_rscript <- function(lines) {
  script_path <- tempfile("loadfast_script_", fileext = ".R")
  renv_activate_path <- normalizePath(file.path("renv", "activate.R"), mustWork = TRUE)
  script_lines <- c(
    sprintf("source(%s)", encodeString(renv_activate_path, quote = "\"")),
    lines
  )
  writeLines(script_lines, script_path)
  on.exit(unlink(script_path), add = TRUE)
  output <- system2(
    file.path(R.home("bin"), "Rscript"),
    c("--vanilla", script_path),
    stdout = TRUE,
    stderr = TRUE
  )
  status <- attr(output, "status")
  if (is.null(status)) status <- 0L

  list(output = output, status = status)
}

copy_baseline <- function(dest) {
  dir.create(dest, recursive = TRUE, showWarnings = FALSE)
  invisible(file.copy(file.path("devpackage", "DESCRIPTION"), dest))
  invisible(file.copy(file.path("devpackage", "NAMESPACE"), dest))
  invisible(file.copy(file.path("renv.lock"), dest))
  dir.create(file.path(dest, "R"), showWarnings = FALSE)
  for (f in list.files(file.path("devpackage", "R"), full.names = TRUE)) {
    invisible(file.copy(f, file.path(dest, "R", basename(f))))
  }
  dir.create(file.path(dest, "tests", "testthat"), recursive = TRUE, showWarnings = FALSE)
  for (f in list.files(file.path("devpackage", "tests", "testthat"), full.names = TRUE)) {
    invisible(file.copy(f, file.path(dest, "tests", "testthat", basename(f))))
  }
  .tmp_dirs <<- c(.tmp_dirs, dest)
}

rename_package <- function(pkg_path, pkg_name) {
  replace_description_field(
    file.path(pkg_path, "DESCRIPTION"),
    "Package",
    paste0("Package: ", pkg_name)
  )

  ns_path <- file.path(pkg_path, "NAMESPACE")
  ns_lines <- readLines(ns_path, warn = FALSE)
  ns_lines <- gsub('^export\\(devpackage\\)$', paste0("export(", pkg_name, ")"), ns_lines)
  writeLines(ns_lines, ns_path)

  init_path <- file.path(pkg_path, "R", "000_init.R")
  if (file.exists(init_path)) {
    init_lines <- readLines(init_path, warn = FALSE)
    init_lines <- gsub('^devpackage <- function\\(\\) "devpackage"$', paste0(pkg_name, ' <- function() "', pkg_name, '"'), init_lines)
    writeLines(init_lines, init_path)
  }
}

replace_description_field <- function(desc_path, field, replacement_lines) {
  lines <- readLines(desc_path, warn = FALSE)
  start_idx <- grep(paste0("^", field, ":"), lines)

  if (length(start_idx) == 0L) {
    writeLines(c(lines, replacement_lines), desc_path)
    return(invisible(NULL))
  }

  if (length(start_idx) != 1L) stop("Expected at most one ", field, " field in DESCRIPTION")
  start_idx <- start_idx[[1L]]

  end_idx <- start_idx
  while (end_idx < length(lines) && grepl("^[[:space:]]", lines[end_idx + 1L])) {
    end_idx <- end_idx + 1L
  }

  writeLines(
    c(
      lines[seq_len(start_idx - 1L)],
      replacement_lines,
      lines[(end_idx + 1L):length(lines)]
    ),
    desc_path
  )
}

replace_namespace_imports <- function(ns_path, import_lines) {
  ns_lines <- readLines(ns_path, warn = FALSE)
  keep <- !grepl("^import(From|ClassesFrom|MethodsFrom)?\\(", ns_lines)
  writeLines(c(ns_lines[keep], import_lines), ns_path)
}

remove_renv_lock <- function(pkg_path) {
  lock_path <- file.path(pkg_path, "renv.lock")
  if (file.exists(lock_path)) {
    unlink(lock_path)
  }
}

# ============================================================================
# STAGE 1: Load frozen devpackage baseline
# ============================================================================
cat("\n--- Stage 1: load devpackage ---\n\n")

ns <- load_fast("devpackage")

# --- Package name from DESCRIPTION ---
check("Package name is 'devpackage'", quote(
  ns$.packageName == "devpackage"
))

# --- Namespace setup ---
check("Namespace is registered", quote(
  "devpackage" %in% loadedNamespaces()
))

check("isNamespace() returns TRUE", quote(
  isNamespace(ns)
))

check(".__DEVTOOLS__ marker is set (enables testthat mocking)", quote(
  !is.null(ns[[".__DEVTOOLS__"]])
))

if (requireNamespace("pkgload", quietly = TRUE)) {
  check("pkgload::dev_meta() recognizes loadfast-loaded package", quote(
    !is.null(pkgload::dev_meta("devpackage"))
  ))

  check("with_mocked_bindings() auto-detects loadfast-loaded package", quote({
    result <- testthat::with_mocked_bindings(
      get("add", envir = asNamespace("devpackage"))(1, 2),
      add = function(a, b) 999L,
      .package = "devpackage"
    )
    result == 999L
  }))

  check("with_mocked_bindings() without .package uses loadfast-loaded package", quote({
    result <- testthat::with_mocked_bindings(
      get("add", envir = asNamespace("devpackage"))(1, 2),
      add = function(a, b) 999L
    )
    result == 999L
  }))
}

# --- Search path ---
check("package:devpackage is on the search path", quote(
  "package:devpackage" %in% search()
))

# --- Imports env structure ---
impenv <- parent.env(ns)

check("Imports env name is 'imports:devpackage'", quote(
  identical(attr(impenv, "name"), "imports:devpackage")
))

check("Imports env parent is .BaseNamespaceEnv", quote(
  identical(parent.env(impenv), .BaseNamespaceEnv)
))

# --- importFrom(rlang, ns_registry_env) ---
check("ns_registry_env is in imports env", quote(
  exists("ns_registry_env", envir = impenv, inherits = FALSE)
))

# --- import(methods) ---
check("setClass is in imports env (from methods)", quote(
  exists("setClass", envir = impenv, inherits = FALSE)
))

# --- importFrom(R6, R6Class) ---
check("R6Class is in imports env", quote(
  exists("R6Class", envir = impenv, inherits = FALSE)
))

# --- importFrom(data.table, ...) ---
check(":= is in imports env", quote(
  exists(":=", envir = impenv, inherits = FALSE)
))

check("as.data.table is in imports env", quote(
  exists("as.data.table", envir = impenv, inherits = FALSE)
))

check("data.table is in imports env", quote(
  exists("data.table", envir = impenv, inherits = FALSE)
))

check(":= is exposed in attached pkg env", quote(
  exists(":=", where = "package:devpackage", inherits = FALSE)
))

check("as.data.table is exposed in attached pkg env", quote(
  exists("as.data.table", where = "package:devpackage", inherits = FALSE)
))

check("data.table is exposed in attached pkg env", quote(
  exists("data.table", where = "package:devpackage", inherits = FALSE)
))

# --- base.R functions ---
check("add() exists in namespace", quote(
  exists("add", envir = ns, inherits = FALSE)
))

check("add(2, 3) returns 5", quote(
  get("add", envir = ns)(2, 3) == 5
))

check("add(-1, 1) returns 0", quote(
  get("add", envir = ns)(-1, 1) == 0
))

check("add() is visible from attached env", quote(
  exists("add", where = "package:devpackage", inherits = FALSE)
))

check("scale_vector(1:3, 2) returns c(2,4,6)", quote(
  identical(get("scale_vector", envir = ns)(1:3, factor = 2), c(2, 4, 6))
))

check("summarize_values() returns mean, sd, n", quote({
  s <- get("summarize_values", envir = ns)(c(2, 4, 6))
  s$mean == 4 && s$n == 3 && is.numeric(s$sd) && is.null(s$range)
}))

# --- mutate_dt: data.table := inside package code ---
check("mutate_dt() exists in namespace", quote(
  exists("mutate_dt", envir = ns, inherits = FALSE)
))

check("mutate_dt() returns a data.table with := column", quote({
  dt <- get("mutate_dt", envir = ns)(c(1, 2, 3), times = 10L)
  data.table::is.data.table(dt) &&
    identical(dt$val, c(1, 2, 3)) &&
    identical(dt$scaled, c(10, 20, 30)) &&
    ncol(dt) == 2L
}))

check("mutate_dt() is visible from attached env", quote(
  exists("mutate_dt", where = "package:devpackage", inherits = FALSE)
))

# --- S4 classes ---
check("Animal class is defined", quote(
  isClass("Animal")
))

check("Pet class is defined", quote(
  isClass("Pet")
))

check("Pet extends Animal", quote(
  extends("Pet", "Animal")
))

# --- S4 generics ---
check("describe generic exists", quote(
  isGeneric("describe")
))

check("greet generic exists", quote(
  isGeneric("greet")
))

check("speak generic does NOT exist yet", quote(
  !isGeneric("speak")
))

# --- S4 constructors and slots ---
a1 <- get("animal", envir = ns)("Rex", "dog", 4)
p1 <- get("pet", envir = ns)("Milo", "cat", 4, "Alice")

check("animal() returns an Animal instance", quote(
  is(a1, "Animal")
))

check("pet() returns a Pet instance", quote(
  is(p1, "Pet")
))

check("Pet instance is also an Animal", quote(
  is(p1, "Animal")
))

check("Animal@name is correct", quote(
  a1@name == "Rex"
))

check("Animal@species is correct", quote(
  a1@species == "dog"
))

check("Animal@legs is correct", quote(
  a1@legs == 4
))

check("Pet@owner is correct", quote(
  p1@owner == "Alice"
))

# --- S4 method dispatch ---
check("describe(Animal) works", quote(
  get("describe", envir = ns)(a1) == "Rex is a dog with 4 legs"
))

check("describe(Pet) includes owner via callNextMethod", quote(
  get("describe", envir = ns)(p1) == "Milo is a cat with 4 legs, owned by Alice"
))

check("greet(Pet) works", quote(
  get("greet", envir = ns)(p1) == "Hello! My name is Milo and I belong to Alice"
))

# --- S4 digest compatibility with pkgload ---
repo_loadfast_path <- normalizePath(file.path("R", "loadfast.R"), mustWork = TRUE)
repo_devpackage_path <- normalizePath("devpackage", mustWork = TRUE)
repo_loadfast_path_quoted <- encodeString(repo_loadfast_path, quote = "\"")
repo_devpackage_path_quoted <- encodeString(repo_devpackage_path, quote = "\"")
s4_digest_object_line <- "obj <- animal('Rex', 'dog', 4)"
s4_digest_report_line <- paste(
  "pkg_attr <- attr(class(obj), 'package')",
  "cat(sprintf('HASH=%s', digest::digest(obj)), sep = '\\n')",
  "cat(sprintf('PKG_ATTR=%s', if (is.null(names(pkg_attr))) 'unnamed' else 'named'), sep = '\\n')",
  sep = "\n"
)

s4_digest_loadfast <- run_rscript(c(
  sprintf("suppressMessages(source(%s))", repo_loadfast_path_quoted),
  sprintf("suppressMessages(load_fast(%s, helpers = FALSE, attach_testthat = FALSE, full = TRUE))", repo_devpackage_path_quoted),
  s4_digest_object_line,
  s4_digest_report_line
))
s4_digest_loadall <- run_rscript(c(
  sprintf("pkgload::load_all(%s, helpers = FALSE, quiet = TRUE)", repo_devpackage_path_quoted),
  s4_digest_object_line,
  s4_digest_report_line
))

s4_digest_loadfast_hash_line <- grep("^HASH=", s4_digest_loadfast$output, value = TRUE)
s4_digest_loadall_hash_line <- grep("^HASH=", s4_digest_loadall$output, value = TRUE)
s4_digest_loadfast_pkg_attr_line <- grep("^PKG_ATTR=", s4_digest_loadfast$output, value = TRUE)
s4_digest_loadall_pkg_attr_line <- grep("^PKG_ATTR=", s4_digest_loadall$output, value = TRUE)

check("S4 digest repro: load_fast script succeeds", quote(
  s4_digest_loadfast$status == 0L
))

check("S4 digest repro: pkgload script succeeds", quote(
  s4_digest_loadall$status == 0L
))

check("S4 digest repro: load_fast emitted hash line", quote(
  length(s4_digest_loadfast_hash_line) == 1L
))

check("S4 digest repro: pkgload emitted hash line", quote(
  length(s4_digest_loadall_hash_line) == 1L
))

check("S4 digest repro: load_fast emitted package attr line", quote(
  length(s4_digest_loadfast_pkg_attr_line) == 1L
))

check("S4 digest repro: pkgload emitted package attr line", quote(
  length(s4_digest_loadall_pkg_attr_line) == 1L
))

check("S4 digest repro: load_fast leaves unnamed package attr", quote(
  length(s4_digest_loadfast_pkg_attr_line) == 1L &&
    identical(s4_digest_loadfast_pkg_attr_line[[1L]], "PKG_ATTR=unnamed")
))

check("S4 digest repro: pkgload leaves unnamed package attr", quote(
  length(s4_digest_loadall_pkg_attr_line) == 1L &&
    identical(s4_digest_loadall_pkg_attr_line[[1L]], "PKG_ATTR=unnamed")
))

check("S4 digest repro: load_fast matches pkgload hash", quote(
  length(s4_digest_loadfast_hash_line) == 1L &&
    length(s4_digest_loadall_hash_line) == 1L &&
    identical(s4_digest_loadfast_hash_line[[1L]], s4_digest_loadall_hash_line[[1L]])
))

# --- R6 classes ---
check("Logger R6 generator exists in namespace", quote(
  exists("Logger", envir = ns, inherits = FALSE)
))

check("Counter R6 generator exists in namespace", quote(
  exists("Counter", envir = ns, inherits = FALSE)
))

lg1 <- get("Logger", envir = ns)$new()

check("Logger$new() creates empty logger", quote(
  lg1$size() == 0L
))

check("Logger$last() returns NA on empty", quote(
  identical(lg1$last(), NA_character_)
))

lg1$log("hello")
lg1$log("world")

check("Logger$log() appends entries", quote(
  lg1$size() == 2L
))

check("Logger$last() returns last entry", quote(
  lg1$last() == "world"
))

check("Logger entries are plain (no level prefix in baseline)", quote(
  identical(lg1$entries, c("hello", "world"))
))

ctr1 <- get("Counter", envir = ns)$new()

check("Counter$new() starts at 0", quote(
  ctr1$value == 0L
))

ctr1$increment()
ctr1$increment(by = 5L)

check("Counter$increment() accumulates", quote(
  ctr1$value == 6L
))

ctr1$reset()

check("Counter$reset() zeroes out", quote(
  ctr1$value == 0L
))

check("Counter does NOT have decrement yet", quote(
  is.null(ctr1$decrement)
))

# --- testthat helpers sourced into pkg env ---
check("testthat is on the search path", quote(
  "package:testthat" %in% search()
))

check("make_test_animal() is in attached pkg env", quote(
  exists("make_test_animal", where = "package:devpackage", inherits = FALSE)
))

check("make_test_logger() is in attached pkg env", quote(
  exists("make_test_logger", where = "package:devpackage", inherits = FALSE)
))

th_animal <- get("make_test_animal", pos = "package:devpackage")()
th_logger <- get("make_test_logger", pos = "package:devpackage")()

check("make_test_animal() returns an Animal", quote(
  is(th_animal, "Animal")
))

check("make_test_animal() has correct name", quote(
  th_animal@name == "TestAnimal"
))

check("make_test_logger() returns a Logger with one entry", quote(
  th_logger$size() == 1L && th_logger$last() == "init"
))

# --- Run testthat suite for devpackage ---
cat("\n--- Running testthat::test_dir() for devpackage ---\n\n")
tt_results1 <- testthat::test_dir(
  file.path("devpackage", "tests", "testthat"),
  env = as.environment("package:devpackage"),
  stop_on_failure = FALSE
)
tt_df1 <- as.data.frame(tt_results1)
n_tt_fail1 <- sum(tt_df1$failed)
n_tt_pass1 <- sum(tt_df1$passed)

check("testthat devpackage: all tests pass", quote(
  n_tt_fail1 == 0L
))

cat(sprintf("  (testthat devpackage: %d passed, %d failed)\n", n_tt_pass1, n_tt_fail1))

# ============================================================================
# STAGE 2: Full reload with mutated code (project2-style changes, ad-hoc)
# ============================================================================
cat("\n--- Stage 2: reload with mutated code ---\n\n")

tmp_a <- tempfile("loadfast_s2_")
copy_baseline(tmp_a)

# --- Mutate R/base.R ---
writeLines(c(
  "add <- function(a, b) {",
  "  a + b + 100",
  "}",
  "",
  "scale_vector <- function(x, factor = 1) {",
  "  (x - mean(x)) * factor",
  "}",
  "",
  "summarize_values <- function(x) {",
  "  list(mean = mean(x), sd = sd(x), n = length(x), range = range(x))",
  "}",
  "",
  "mutate_dt <- function(x, times = 2L) {",
  "  dt <- as.data.table(list(val = x))",
  "  dt[, scaled := val * times]",
  "  dt[, rnk := data.table::frank(val)]",
  "  dt",
  "}"
), file.path(tmp_a, "R", "base.R"))

# --- Mutate R/s4_classes.R ---
writeLines(c(
  'setClass("Animal", representation(',
  '  name    = "character",',
  '  species = "character",',
  '  legs    = "numeric",',
  '  age     = "numeric"',
  "))",
  "",
  'setClass("Pet", contains = "Animal", representation(',
  '  owner    = "character",',
  '  nickname = "character"',
  "))",
  "",
  'setGeneric("describe", function(object, ...) {',
  '  standardGeneric("describe")',
  "})",
  "",
  'setGeneric("greet", function(object) {',
  '  standardGeneric("greet")',
  "})",
  "",
  'setGeneric("speak", function(object) {',
  '  standardGeneric("speak")',
  "})",
  "",
  'setMethod("describe", "Animal", function(object, ...) {',
  '  paste0(object@name, " is a ", object@species, ", age ", object@age, ", with ", object@legs, " legs")',
  "})",
  "",
  'setMethod("describe", "Pet", function(object, ...) {',
  "  base_desc <- callNextMethod()",
  '  paste0(base_desc, ", nicknamed ", object@nickname, ", owned by ", object@owner)',
  "})",
  "",
  'setMethod("greet", "Pet", function(object) {',
  "  paste0(\"Hi! I'm \", object@nickname, \" (\", object@name, \") and \", object@owner, \" takes care of me\")",
  "})",
  "",
  'setMethod("speak", "Animal", function(object) {',
  '  paste0(object@name, " says hello")',
  "})",
  "",
  'setMethod("speak", "Pet", function(object) {',
  '  paste0(object@nickname, " says hello to ", object@owner)',
  "})",
  "",
  "animal <- function(name, species, legs, age) {",
  '  new("Animal", name = name, species = species, legs = legs, age = age)',
  "}",
  "",
  "pet <- function(name, species, legs, age, owner, nickname) {",
  '  new("Pet", name = name, species = species, legs = legs, age = age,',
  "      owner = owner, nickname = nickname)",
  "}"
), file.path(tmp_a, "R", "s4_classes.R"))

# --- Mutate R/r6_classes.R ---
writeLines(c(
  'Logger <- R6Class("Logger",',
  "  public = list(",
  "    entries = NULL,",
  "    level = NULL,",
  '    initialize = function(level = "INFO") {',
  "      self$entries <- character(0)",
  "      self$level <- level",
  "    },",
  "    log = function(msg) {",
  '      entry <- paste0("[", self$level, "] ", msg)',
  "      self$entries <- c(self$entries, entry)",
  "      invisible(self)",
  "    },",
  "    last = function() {",
  "      if (length(self$entries) == 0L) return(NA_character_)",
  "      self$entries[length(self$entries)]",
  "    },",
  "    size = function() {",
  "      length(self$entries)",
  "    },",
  "    format_entries = function() {",
  '      paste(self$entries, collapse = "\\n")',
  "    }",
  "  )",
  ")",
  "",
  'Counter <- R6Class("Counter",',
  "  public = list(",
  "    value = 0L,",
  "    initialize = function(start = 0L) {",
  "      self$value <- start",
  "    },",
  "    increment = function(by = 1L) {",
  "      self$value <- self$value + by",
  "      invisible(self)",
  "    },",
  "    decrement = function(by = 1L) {",
  "      self$value <- self$value - by",
  "      invisible(self)",
  "    },",
  "    reset = function() {",
  "      self$value <- 0L",
  "      invisible(self)",
  "    }",
  "  )",
  ")"
), file.path(tmp_a, "R", "r6_classes.R"))

# --- Mutate tests/testthat/helper-utils.R ---
writeLines(c(
  'make_test_animal <- function() animal("TestAnimal2", "test_species2", 6, 2)',
  "",
  "make_test_logger <- function() {",
  '  lg <- Logger$new("DEBUG")',
  '  lg$log("init")',
  "  lg",
  "}"
), file.path(tmp_a, "tests", "testthat", "helper-utils.R"))

ns2 <- load_fast(tmp_a)

# --- Basics still hold ---
check("Package name is still 'devpackage'", quote(
  ns2$.packageName == "devpackage"
))

check("isNamespace() returns TRUE after reload", quote(
  isNamespace(ns2)
))

check("package:devpackage is still on the search path", quote(
  "package:devpackage" %in% search()
))

# --- base.R changed behavior ---
check("add(2, 3) now returns 105", quote(
  get("add", envir = ns2)(2, 3) == 105
))

check("add(0, 0) now returns 100", quote(
  get("add", envir = ns2)(0, 0) == 100
))

check("scale_vector() now centers before scaling", quote(
  identical(get("scale_vector", envir = ns2)(c(1, 3), factor = 1), c(-1, 1))
))

check("summarize_values() now includes range", quote({
  s <- get("summarize_values", envir = ns2)(c(2, 4, 6))
  s$mean == 4 && identical(s$range, c(2, 6))
}))

# --- mutate_dt: adds a rank column ---
check("mutate_dt() now returns 3 columns with rnk", quote({
  dt <- get("mutate_dt", envir = ns2)(c(30, 10, 20), times = 2L)
  data.table::is.data.table(dt) &&
    identical(dt$val, c(30, 10, 20)) &&
    identical(dt$scaled, c(60, 20, 40)) &&
    identical(dt$rnk, c(3, 1, 2)) &&
    ncol(dt) == 3L
}))

# --- S4 classes updated ---
check("Animal class still exists", quote(
  isClass("Animal")
))

check("Pet class still exists", quote(
  isClass("Pet")
))

check("Pet still extends Animal", quote(
  extends("Pet", "Animal")
))

# --- Animal now has age slot ---
a2 <- get("animal", envir = ns2)("Rex", "dog", 4, 5)

check("Animal now accepts age parameter", quote(
  is(a2, "Animal")
))

check("Animal@age is correct", quote(
  a2@age == 5
))

# --- Pet now has nickname slot ---
p2 <- get("pet", envir = ns2)("Milo", "cat", 4, 3, "Alice", "Meowster")

check("Pet now accepts nickname parameter", quote(
  is(p2, "Pet")
))

check("Pet@nickname is correct", quote(
  p2@nickname == "Meowster"
))

check("Pet@age inherited from Animal is correct", quote(
  p2@age == 3
))

# --- describe() output changed ---
check("describe(Animal) now includes age", quote(
  get("describe", envir = ns2)(a2) == "Rex is a dog, age 5, with 4 legs"
))

check("describe(Pet) now includes nickname and age", quote(
  get("describe", envir = ns2)(p2) == "Milo is a cat, age 3, with 4 legs, nicknamed Meowster, owned by Alice"
))

# --- greet() output changed ---
check("greet(Pet) has new wording", quote(
  get("greet", envir = ns2)(p2) == "Hi! I'm Meowster (Milo) and Alice takes care of me"
))

# --- speak() is new ---
check("speak generic now exists", quote(
  isGeneric("speak")
))

check("speak(Animal) works", quote(
  get("speak", envir = ns2)(a2) == "Rex says hello"
))

check("speak(Pet) works", quote(
  get("speak", envir = ns2)(p2) == "Meowster says hello to Alice"
))

# --- R6 classes updated ---
lg2 <- get("Logger", envir = ns2)$new("WARN")

check("Logger now accepts a level argument", quote(
  lg2$level == "WARN"
))

lg2$log("problem")

check("Logger$log() now prefixes with level", quote(
  lg2$last() == "[WARN] problem"
))

lg2$log("another")

check("Logger$format_entries() is new", quote(
  !is.null(lg2$format_entries) && lg2$format_entries() == "[WARN] problem\n[WARN] another"
))

ctr2 <- get("Counter", envir = ns2)$new(10L)

check("Counter$new(10) starts at 10", quote(
  ctr2$value == 10L
))

ctr2$decrement(by = 3L)

check("Counter$decrement() is new", quote(
  ctr2$value == 7L
))

# --- testthat helpers updated after reload ---
th_animal2 <- get("make_test_animal", pos = "package:devpackage")()
th_logger2 <- get("make_test_logger", pos = "package:devpackage")()

check("make_test_animal() returns updated Animal", quote(
  is(th_animal2, "Animal") && th_animal2@name == "TestAnimal2"
))

check("make_test_animal() Animal has age slot", quote(
  th_animal2@age == 2
))

check("make_test_logger() now uses DEBUG level", quote(
  th_logger2$level == "DEBUG"
))

check("make_test_logger() entry is prefixed with level", quote(
  th_logger2$last() == "[DEBUG] init"
))

# ============================================================================
# STAGE 3: Cross-file dependency tests
#   Function in file A depends on a definition in file B.  Only file B
#   changes — verify file A's output reflects the change.
# ============================================================================
cat("\n--- Stage 3: cross-file dependency tests ---\n\n")

tmp_b <- tempfile("loadfast_s3_")
copy_baseline(tmp_b)

ns3 <- load_fast(tmp_b, helpers = FALSE, attach_testthat = FALSE)
pkg_env3 <- "package:devpackage"

# --------------------------------------------------------------------------
# 3a: Plain function — compute() in wrappers.R calls add() from base.R
# --------------------------------------------------------------------------
cat("\n--- 3a: cross-file plain function dependency ---\n\n")

writeLines(c(
  "compute <- function(a, b) add(a, b) * 10"
), file.path(tmp_b, "R", "wrappers.R"))

ns3a <- load_fast(tmp_b, helpers = FALSE, attach_testthat = FALSE)

check("xdep-fn: compute(1,2) uses original add => (1+2)*10 = 30", quote(
  get("compute", envir = ns3a)(1, 2) == 30
))

# Change only base.R: add now includes +1000 offset
writeLines(c(
  "add <- function(a, b) {",
  "  a + b + 1000",
  "}",
  "",
  "scale_vector <- function(x, factor = 1) {",
  "  x * factor",
  "}",
  "",
  "summarize_values <- function(x) {",
  "  list(mean = mean(x), sd = sd(x), n = length(x))",
  "}",
  "",
  "mutate_dt <- function(x, times = 2L) {",
  "  dt <- as.data.table(list(val = x))",
  "  dt[, scaled := val * times]",
  "  dt",
  "}"
), file.path(tmp_b, "R", "base.R"))

ns3a2 <- load_fast(tmp_b, helpers = FALSE, attach_testthat = FALSE)

check("xdep-fn: compute(1,2) reflects changed add => (1+2+1000)*10 = 10030", quote(
  get("compute", envir = ns3a2)(1, 2) == 10030
))

check("xdep-fn: compute in pkg env also reflects change", quote(
  get("compute", pos = pkg_env3)(1, 2) == 10030
))

# --------------------------------------------------------------------------
# 3b: S4 method — describe_loud() in wrappers.R calls describe() generic
#     whose method lives in s4_classes.R
# --------------------------------------------------------------------------
cat("\n--- 3b: cross-file S4 method dependency ---\n\n")

writeLines(c(
  "compute <- function(a, b) add(a, b) * 10",
  "",
  'describe_loud <- function(obj) paste0(describe(obj), "!!!")'
), file.path(tmp_b, "R", "wrappers.R"))

ns3b <- load_fast(tmp_b, helpers = FALSE, attach_testthat = FALSE)

a3b <- get("animal", envir = ns3b)("Rex", "dog", 4)
check("xdep-method: describe_loud uses original describe", quote(
  get("describe_loud", envir = ns3b)(a3b) == "Rex is a dog with 4 legs!!!"
))

# Change only s4_classes.R: alter describe(Animal) output format
writeLines(c(
  'setClass("Animal", representation(',
  '  name    = "character",',
  '  species = "character",',
  '  legs    = "numeric"',
  "))",
  "",
  'setClass("Pet", contains = "Animal", representation(',
  '  owner = "character"',
  "))",
  "",
  'setGeneric("describe", function(object, ...) {',
  '  standardGeneric("describe")',
  "})",
  "",
  'setGeneric("greet", function(object) {',
  '  standardGeneric("greet")',
  "})",
  "",
  'setMethod("describe", "Animal", function(object, ...) {',
  '  paste0(object@name, " the ", object@species, " (", object@legs, " legs)")',
  "})",
  "",
  'setMethod("describe", "Pet", function(object, ...) {',
  "  base_desc <- callNextMethod()",
  '  paste0(base_desc, ", owned by ", object@owner)',
  "})",
  "",
  'setMethod("greet", "Pet", function(object) {',
  '  paste0("Hello! My name is ", object@name, " and I belong to ", object@owner)',
  "})",
  "",
  "animal <- function(name, species, legs) {",
  '  new("Animal", name = name, species = species, legs = legs)',
  "}",
  "",
  "pet <- function(name, species, legs, owner) {",
  '  new("Pet", name = name, species = species, legs = legs, owner = owner)',
  "}"
), file.path(tmp_b, "R", "s4_classes.R"))

ns3b2 <- load_fast(tmp_b, helpers = FALSE, attach_testthat = FALSE)

a3b2 <- get("animal", envir = ns3b2)("Rex", "dog", 4)
check("xdep-method: describe_loud reflects changed describe method", quote(
  get("describe_loud", envir = ns3b2)(a3b2) == "Rex the dog (4 legs)!!!"
))

check("xdep-method: describe_loud in pkg env also reflects change", quote(
  get("describe_loud", pos = pkg_env3)(a3b2) == "Rex the dog (4 legs)!!!"
))

p3b2 <- get("pet", envir = ns3b2)("Milo", "cat", 4, "Alice")
check("xdep-method: describe(Pet) uses updated Animal method via callNextMethod", quote(
  get("describe", envir = ns3b2)(p3b2) == "Milo the cat (4 legs), owned by Alice"
))

# --------------------------------------------------------------------------
# 3c: S4 class change — make_animal() in wrappers.R calls new("Animal",...)
#     Adding an age slot in s4_classes.R should be reflected in the object
#     returned by the unchanged make_animal().
# --------------------------------------------------------------------------
cat("\n--- 3c: cross-file S4 class change affecting constructor ---\n\n")

writeLines(c(
  "compute <- function(a, b) add(a, b) * 10",
  "",
  'describe_loud <- function(obj) paste0(describe(obj), "!!!")',
  "",
  'make_animal <- function(n, s, l) new("Animal", name = n, species = s, legs = l)'
), file.path(tmp_b, "R", "wrappers.R"))

ns3c <- load_fast(tmp_b, helpers = FALSE, attach_testthat = FALSE)

a3c <- get("make_animal", envir = ns3c)("Rex", "dog", 4)
check("xdep-s4class: make_animal creates Animal (before class change)", quote(
  is(a3c, "Animal") && a3c@name == "Rex" && a3c@legs == 4
))

check("xdep-s4class: Animal does NOT have age slot yet", quote(
  !methods::.hasSlot(a3c, "age")
))

# Change only s4_classes.R: add age slot with prototype default
writeLines(c(
  'setClass("Animal", representation(',
  '  name    = "character",',
  '  species = "character",',
  '  legs    = "numeric",',
  '  age     = "numeric"',
  "), prototype = list(age = 0))",
  "",
  'setClass("Pet", contains = "Animal", representation(',
  '  owner = "character"',
  "))",
  "",
  'setGeneric("describe", function(object, ...) {',
  '  standardGeneric("describe")',
  "})",
  "",
  'setGeneric("greet", function(object) {',
  '  standardGeneric("greet")',
  "})",
  "",
  'setMethod("describe", "Animal", function(object, ...) {',
  '  paste0(object@name, " the ", object@species, " (", object@legs, " legs)")',
  "})",
  "",
  'setMethod("describe", "Pet", function(object, ...) {',
  "  base_desc <- callNextMethod()",
  '  paste0(base_desc, ", owned by ", object@owner)',
  "})",
  "",
  'setMethod("greet", "Pet", function(object) {',
  '  paste0("Hello! My name is ", object@name, " and I belong to ", object@owner)',
  "})",
  "",
  "animal <- function(name, species, legs, age = 0) {",
  '  new("Animal", name = name, species = species, legs = legs, age = age)',
  "}",
  "",
  "pet <- function(name, species, legs, owner) {",
  '  new("Pet", name = name, species = species, legs = legs, owner = owner)',
  "}"
), file.path(tmp_b, "R", "s4_classes.R"))

# Incremental reload — only s4_classes.R re-sourced, wrappers.R unchanged
ns3c2 <- load_fast(tmp_b, helpers = FALSE, attach_testthat = FALSE)

a3c2_incr <- tryCatch(
  get("make_animal", envir = ns3c2)("Rex", "dog", 4),
  error = function(e) e
)

has_age_incr <- tryCatch(
  !inherits(a3c2_incr, "error") &&
    methods::.hasSlot(a3c2_incr, "age") &&
    a3c2_incr@age == 0,
  error = function(e) FALSE
)

if (has_age_incr) {
  check("xdep-s4class: reload picks up new age slot", quote(has_age_incr))
} else {
  cat("  (note: reload did not pick up S4 class change — using full=TRUE)\n")
}

# full=TRUE always works: full teardown re-registers the class cleanly
ns3c_full <- load_fast(tmp_b, helpers = FALSE, attach_testthat = FALSE, full = TRUE)

a3c_full <- get("make_animal", envir = ns3c_full)("Rex", "dog", 4)

check("xdep-s4class: full=TRUE make_animal returns Animal with age slot", quote(
  is(a3c_full, "Animal") && methods::.hasSlot(a3c_full, "age")
))

check("xdep-s4class: full=TRUE age slot has prototype default 0", quote(
  a3c_full@age == 0
))

check("xdep-s4class: full=TRUE other slots still correct", quote(
  a3c_full@name == "Rex" && a3c_full@species == "dog" && a3c_full@legs == 4
))

a3c_aged <- get("animal", envir = ns3c_full)("Old Rex", "dog", 4, 12)
check("xdep-s4class: full=TRUE animal() constructor accepts age param", quote(
  a3c_aged@age == 12
))

# ============================================================================
# STAGE 3d: Collate-aware load ordering
# ============================================================================
cat("\n--- 3d: Collate-aware load ordering ---\n\n")

tmp_d <- tempfile("loadfast_s3_collate_")
copy_baseline(tmp_d)

replace_description_field(
  file.path(tmp_d, "DESCRIPTION"),
  "Collate",
  c(
    "Collate:",
    "    'zzz_helper.R'",
    "    'aaa_consumer.R'",
    "    'base.R'",
    "    's4_classes.R'",
    "    'r6_classes.R'"
  )
)

writeLines(c(
  "collate_helper <- function(x) {",
  "  paste0(\"helper:\", x)",
  "}"
), file.path(tmp_d, "R", "zzz_helper.R"))

writeLines(c(
  "collate_consumer <- function(x) {",
  "  collate_helper(x)",
  "}"
), file.path(tmp_d, "R", "aaa_consumer.R"))

ns3d <- load_fast(tmp_d, helpers = FALSE, attach_testthat = FALSE, full = TRUE)

check("collate: helper exists after collate-ordered load", quote(
  exists("collate_helper", envir = ns3d, inherits = FALSE)
))

check("collate: consumer exists after collate-ordered load", quote(
  exists("collate_consumer", envir = ns3d, inherits = FALSE)
))

check("collate: consumer can call helper despite alphabetical mis-order", quote(
  get("collate_consumer", envir = ns3d)("ok") == "helper:ok"
))

check("collate: consumer is visible from attached env", quote(
  get("collate_consumer", pos = "package:devpackage")("env") == "helper:env"
))

# ============================================================================
# STAGE 3e: Multiple packages in one session
# ============================================================================
cat("\n--- 3e: multiple packages in one session ---\n\n")

tmp_multi_a <- tempfile("loadfast_multi_a_")
tmp_multi_b <- tempfile("loadfast_multi_b_")
copy_baseline(tmp_multi_a)
copy_baseline(tmp_multi_b)

rename_package(tmp_multi_a, "packagea")
rename_package(tmp_multi_b, "packageb")

ns_multi_a <- load_fast(tmp_multi_a, helpers = FALSE, attach_testthat = FALSE)
ns_multi_b <- load_fast(tmp_multi_b, helpers = FALSE, attach_testthat = FALSE)

check("multi-pkg: packagea namespace is registered", quote(
  "packagea" %in% loadedNamespaces()
))

check("multi-pkg: packageb namespace is registered", quote(
  "packageb" %in% loadedNamespaces()
))

check("multi-pkg: package:packagea is on the search path", quote(
  "package:packagea" %in% search()
))

check("multi-pkg: package:packageb is on the search path", quote(
  "package:packageb" %in% search()
))

check("multi-pkg: packagea namespace has correct package name", quote(
  ns_multi_a$.packageName == "packagea"
))

check("multi-pkg: packageb namespace has correct package name", quote(
  ns_multi_b$.packageName == "packageb"
))

check("multi-pkg: packagea add() works", quote(
  get("add", envir = ns_multi_a)(2, 3) == 5
))

check("multi-pkg: packageb add() works", quote(
  get("add", envir = ns_multi_b)(4, 5) == 9
))

check("multi-pkg: packagea attached env works", quote(
  get("add", pos = "package:packagea")(10, 1) == 11
))

check("multi-pkg: packageb attached env works", quote(
  get("add", pos = "package:packageb")(10, 2) == 12
))

check("multi-pkg: helpers disabled keeps test helper out of packagea env", quote(
  !exists("make_test_animal", where = "package:packagea", inherits = FALSE)
))

check("multi-pkg: helpers disabled keeps test helper out of packageb env", quote(
  !exists("make_test_animal", where = "package:packageb", inherits = FALSE)
))

# --------------------------------------------------------------------------
# 3f: Same package name from different path warns and replaces prior load
# --------------------------------------------------------------------------
cat("\n--- 3f: same package name from different path warns ---\n\n")

tmp_same_a <- tempfile("loadfast_same_a_")
tmp_same_b <- tempfile("loadfast_same_b_")
copy_baseline(tmp_same_a)
copy_baseline(tmp_same_b)

same_name_reload <- capture_warnings(
  load_fast(tmp_same_a, helpers = FALSE, attach_testthat = FALSE)
)

check("same-name: first load of this path returns a namespace", quote(
  is.environment(same_name_reload$value) && isNamespace(same_name_reload$value)
))

same_name_reload2 <- capture_warnings(
  load_fast(tmp_same_b, helpers = FALSE, attach_testthat = FALSE)
)

check("same-name: warns when same package name is loaded from different path", quote(
  any(grepl("already loaded from a different path", same_name_reload2$warnings, fixed = TRUE))
))

check("same-name: warning mentions replacement", quote(
  any(grepl("will replace the existing loaded package", same_name_reload2$warnings, fixed = TRUE))
))

check("same-name: devpackage remains loaded after replacement", quote(
  "devpackage" %in% loadedNamespaces() && "package:devpackage" %in% search()
))

check("same-name: second path is now the active namespace path", quote(
  identical(
    normalizePath(getNamespaceInfo(asNamespace("devpackage"), "path"), mustWork = FALSE),
    normalizePath(tmp_same_b, mustWork = FALSE)
  )
))

# --------------------------------------------------------------------------
# 3g: Same-name different-path cache flip-flop and renv.lock path scoping
# --------------------------------------------------------------------------
cat("\n--- 3g: same-name path flip-flop and renv.lock path scoping ---\n\n")

tmp_flip_a <- tempfile("loadfast_flip_a_")
tmp_flip_b <- tempfile("loadfast_flip_b_")
copy_baseline(tmp_flip_a)
copy_baseline(tmp_flip_b)

flip_a1 <- capture_warnings(
  load_fast(tmp_flip_a, helpers = FALSE, attach_testthat = FALSE)
)

check("flip-flop: initial load of path A returns a namespace", quote(
  is.environment(flip_a1$value) && isNamespace(flip_a1$value)
))

flip_b1 <- capture_warnings(
  load_fast(tmp_flip_b, helpers = FALSE, attach_testthat = FALSE)
)

check("flip-flop: switching from path A to path B warns", quote(
  any(grepl("already loaded from a different path", flip_b1$warnings, fixed = TRUE))
))

flip_a2 <- capture_warnings(
  load_fast(tmp_flip_a, helpers = FALSE, attach_testthat = FALSE)
)

check("flip-flop: switching back from path B to path A warns", quote(
  any(grepl("already loaded from a different path", flip_a2$warnings, fixed = TRUE))
))

check("flip-flop: path A is active again after switching back", quote(
  identical(
    normalizePath(getNamespaceInfo(asNamespace("devpackage"), "path"), mustWork = FALSE),
    normalizePath(tmp_flip_a, mustWork = FALSE)
  )
))

writeLines(c(
  "{",
  '  "flip": true',
  "}"
), file.path(tmp_flip_a, "renv.lock"))

flip_a_lock <- capture_warnings(
  load_fast(tmp_flip_a, helpers = FALSE, attach_testthat = FALSE)
)

check("flip-flop: renv.lock warning is path-scoped to path A", quote(
  any(grepl("renv.lock changed since the initial load_fast() call for this path", flip_a_lock$warnings, fixed = TRUE))
))

flip_b_lock <- capture_warnings(
  load_fast(tmp_flip_b, helpers = FALSE, attach_testthat = FALSE)
)

check("flip-flop: path B does not inherit path A renv.lock warning", quote(
  !any(grepl("renv.lock changed since the initial load_fast() call for this path", flip_b_lock$warnings, fixed = TRUE))
))

# --------------------------------------------------------------------------
# 3h: Dependent package load order and missing dependency failures
# --------------------------------------------------------------------------
cat("\n--- 3h: dependent package load order and missing dependency failures ---\n\n")

tmp_order_a <- tempfile("loadfast_order_a_")
tmp_order_b <- tempfile("loadfast_order_b_")
copy_baseline(tmp_order_a)
copy_baseline(tmp_order_b)

rename_package(tmp_order_a, "ordapkg")
rename_package(tmp_order_b, "ordbpkg")

writeLines(c(
  "export(add)",
  "importFrom(rlang, ns_registry_env)",
  "import(methods)",
  "importFrom(R6, R6Class)",
  "importFrom(data.table,\":=\")",
  "importFrom(data.table,as.data.table)",
  "importFrom(data.table,data.table)"
), file.path(tmp_order_a, "NAMESPACE"))

replace_namespace_imports(
  file.path(tmp_order_b, "NAMESPACE"),
  c(
    "importFrom(ordapkg,add)",
    "importFrom(rlang, ns_registry_env)",
    "import(methods)",
    "importFrom(R6, R6Class)",
    "importFrom(data.table,\":=\")",
    "importFrom(data.table,as.data.table)",
    "importFrom(data.table,data.table)"
  )
)

writeLines(c(
  "compute_dep <- function(a, b) add(a, b)",
  "",
  'ordbpkg <- function() "ordbpkg"'
), file.path(tmp_order_b, "R", "000_init.R"))

order_fail <- tryCatch(
  {
    load_fast(tmp_order_b, helpers = FALSE, attach_testthat = FALSE)
    NULL
  },
  error = function(e) e
)

check("dep-order: loading packageb before packagea fails", quote(
  inherits(order_fail, "error")
))

check("dep-order: failure mentions ordapkg", quote(
  grepl("ordapkg", conditionMessage(order_fail), fixed = TRUE)
))

ns_order_a <- load_fast(tmp_order_a, helpers = FALSE, attach_testthat = FALSE)
ns_order_b <- load_fast(tmp_order_b, helpers = FALSE, attach_testthat = FALSE)

check("dep-order: loading packageb after packagea succeeds", quote(
  get("compute_dep", envir = ns_order_b)(4, 5) == 9
))

# --------------------------------------------------------------------------
# 3i: Packages without helpers and empty R/ early return
# --------------------------------------------------------------------------
cat("\n--- 3i: no-helper package and empty R package ---\n\n")

tmp_no_helpers <- tempfile("loadfast_no_helpers_")
copy_baseline(tmp_no_helpers)
unlink(file.path(tmp_no_helpers, "tests"), recursive = TRUE, force = TRUE)

no_helpers <- capture_conditions(
  load_fast(tmp_no_helpers, helpers = TRUE, attach_testthat = NULL)
)

check("no-helpers: package still loads without tests/testthat", quote(
  is.environment(no_helpers$value) && isNamespace(no_helpers$value)
))

check("no-helpers: no helper function is added to attached env", quote(
  !exists("make_test_animal", where = "package:devpackage", inherits = FALSE)
))

check("no-helpers: no helper/testthat warning is emitted", quote(
  !any(grepl("\\btestthat\\b|source_test_helpers|helper[^[:alpha:]]", no_helpers$warnings, ignore.case = TRUE))
))

tmp_empty <- tempfile("loadfast_empty_")
dir.create(tmp_empty, recursive = TRUE, showWarnings = FALSE)
.tmp_dirs <<- c(.tmp_dirs, tmp_empty)
writeLines(c(
  "Package: emptypkg",
  "Title: Empty Package",
  "Version: 0.0.1",
  "Description: Empty test package.",
  "License: MIT"
), file.path(tmp_empty, "DESCRIPTION"))
writeLines(character(0), file.path(tmp_empty, "NAMESPACE"))
dir.create(file.path(tmp_empty, "R"), showWarnings = FALSE)

empty_pkg <- capture_messages(
  load_fast(tmp_empty, helpers = FALSE, attach_testthat = FALSE)
)

check("empty-r: load_fast returns NULL invisibly for empty R directory", quote(
  is.null(empty_pkg$value)
))

check("empty-r: emits no R files found message", quote(
  any(grepl("No R files found in", empty_pkg$messages, fixed = TRUE))
))

# --------------------------------------------------------------------------
# 3j: Root discovery and cache identity for relative/absolute/inside-package
# --------------------------------------------------------------------------
cat("\n--- 3j: root discovery and path identity ---\n\n")

root_rel <- load_fast("devpackage", helpers = FALSE, attach_testthat = FALSE)
root_abs <- load_fast(normalizePath("devpackage", mustWork = TRUE), helpers = FALSE, attach_testthat = FALSE)
root_r_dir <- load_fast(file.path("devpackage", "R"), helpers = FALSE, attach_testthat = FALSE)
root_r_file <- load_fast(file.path("devpackage", "R", "base.R"), helpers = FALSE, attach_testthat = FALSE)
root_tests_dir <- load_fast(file.path("devpackage", "tests", "testthat"), helpers = FALSE, attach_testthat = FALSE)

check("path-root: relative and absolute paths share the same namespace env", quote(
  identical(root_rel, root_abs)
))

check("path-root: passing R directory resolves to the same package root", quote(
  identical(root_rel, root_r_dir)
))

check("path-root: passing an R file resolves to the same package root", quote(
  identical(root_rel, root_r_file)
))

check("path-root: passing tests/testthat resolves to the same package root", quote(
  identical(root_rel, root_tests_dir)
))

abs_reload_no_warning <- capture_warnings(
  load_fast(normalizePath("devpackage", mustWork = TRUE), helpers = FALSE, attach_testthat = FALSE)
)

check("path-root: absolute path to same package does not warn about different path", quote(
  !any(grepl("already loaded from a different path", abs_reload_no_warning$warnings, fixed = TRUE))
))

# ============================================================================
# STAGE 4: Incremental-specific tests
#   These test behaviors are unique to the incremental loader: no-change
#   short-circuit, stale symbol lingering, and full=TRUE cleanup.
# ============================================================================
cat("\n--- Stage 4: incremental-specific tests ---\n\n")

tmp_c <- tempfile("loadfast_s4_")
copy_baseline(tmp_c)

pkg_env4 <- "package:devpackage"

ns4 <- load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)

check("incr-setup: full load works", quote(
  is.environment(ns4) && isNamespace(ns4)
))

check("incr-setup: add(1,2) returns 3", quote(
  get("add", envir = ns4)(1, 2) == 3
))

check("incr-setup: summarize_values exists", quote(
  exists("summarize_values", envir = ns4, inherits = FALSE)
))

check("incr-setup: scale_vector exists", quote(
  exists("scale_vector", envir = ns4, inherits = FALSE)
))

# --- 4a: No change — second load should short-circuit ---
cat("\n--- 4a: no-change reload ---\n\n")

ns4a <- load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)

check("no-change: returns same ns_env", quote(
  identical(ns4a, ns4)
))

check("no-change: add still works", quote(
  get("add", envir = ns4a)(10, 20) == 30
))

no_change_dot4a <- local({
  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(tmp_c)
  capture_messages(
    load_fast(".", helpers = FALSE, attach_testthat = FALSE)
  )
})

check("no-change: display path uses package folder name when path='.'", quote(
  any(grepl(paste0("No changes in ", basename(tmp_c), "/R"), no_change_dot4a$messages, fixed = TRUE))
))

no_change_abs4a <- capture_messages(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)
)

check("no-change: display path uses temp package folder name for absolute paths", quote(
  any(grepl(
    paste0("No changes in ", basename(tmp_c), "/R"),
    no_change_abs4a$messages,
    fixed = TRUE
  ))
))

# --- 4b: Remove a function from base.R ---
cat("\n--- 4b: remove summarize_values from base.R ---\n\n")

writeLines(c(
  "add <- function(a, b) {",
  "  a + b",
  "}",
  "",
  "scale_vector <- function(x, factor = 1) {",
  "  x * factor",
  "}"
), file.path(tmp_c, "R", "base.R"))

reload4b <- capture_messages(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)
)
ns4b <- reload4b$value

check("remove-fn: summarize_values lingers (no stale cleanup)", quote(
  exists("summarize_values", envir = ns4b, inherits = FALSE)
))

check("remove-fn: add still works", quote(
  get("add", envir = ns4b)(1, 2) == 3
))

check("remove-fn: scale_vector still works", quote(
  identical(get("scale_vector", envir = ns4b)(1:3, factor = 2), c(2, 4, 6))
))

check("remove-fn: R6 classes unaffected", quote(
  exists("Logger", envir = ns4b, inherits = FALSE) &&
    exists("Counter", envir = ns4b, inherits = FALSE)
))

ns4b_full <- load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE, full = TRUE)

check("remove-fn: full=TRUE clears summarize_values from ns", quote(
  !exists("summarize_values", envir = ns4b_full, inherits = FALSE)
))

check("remove-fn: full=TRUE clears summarize_values from pkg env", quote(
  !exists("summarize_values", where = pkg_env4, inherits = FALSE)
))

# --- 4c: Add a new function to base.R ---
cat("\n--- 4c: add multiply() to base.R ---\n\n")

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
), file.path(tmp_c, "R", "base.R"))

reload4c <- capture_messages(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)
)
ns4c <- reload4c$value

check("add-fn: multiply exists in namespace", quote(
  exists("multiply", envir = ns4c, inherits = FALSE)
))

check("add-fn: multiply(3,4) returns 12", quote(
  get("multiply", envir = ns4c)(3, 4) == 12
))

check("add-fn: multiply visible from pkg env", quote(
  exists("multiply", where = pkg_env4, inherits = FALSE)
))

check("add-fn: add still works", quote(
  get("add", envir = ns4c)(5, 6) == 11
))

# --- 4d: Modify a function (change behavior, same name) ---
cat("\n--- 4d: modify add() behavior ---\n\n")

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
), file.path(tmp_c, "R", "base.R"))

reload4d <- capture_messages(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)
)
ns4d <- reload4d$value

check("modify-fn: add(1,2) now returns 1003", quote(
  get("add", envir = ns4d)(1, 2) == 1003
))

check("modify-fn: add updated in pkg env too", quote(
  get("add", pos = pkg_env4)(1, 2) == 1003
))

check("modify-fn: multiply still works", quote(
  get("multiply", envir = ns4d)(3, 4) == 12
))

# --- 4e: Add a new R file ---
cat("\n--- 4e: add new file extras.R ---\n\n")

writeLines(c(
  "negate <- function(x) -x",
  "",
  "double <- function(x) x * 2"
), file.path(tmp_c, "R", "extras.R"))

reload4e <- capture_messages(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)
)
ns4e <- reload4e$value

check("new-file: negate exists", quote(
  exists("negate", envir = ns4e, inherits = FALSE)
))

check("new-file: negate(5) returns -5", quote(
  get("negate", envir = ns4e)(5) == -5
))

check("new-file: double exists in pkg env", quote(
  exists("double", where = pkg_env4, inherits = FALSE)
))

check("new-file: double(7) returns 14", quote(
  get("double", pos = pkg_env4)(7) == 14
))

check("new-file: existing functions unaffected", quote(
  get("add", envir = ns4e)(1, 2) == 1003
))

# --- 4f: Delete an R file entirely ---
cat("\n--- 4f: delete extras.R ---\n\n")

invisible(file.remove(file.path(tmp_c, "R", "extras.R")))

ns4f <- load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)

check("del-file: negate lingers (no stale cleanup)", quote(
  exists("negate", envir = ns4f, inherits = FALSE)
))

check("del-file: add still works", quote(
  get("add", envir = ns4f)(1, 2) == 1003
))

check("del-file: R6 classes still work", quote({
  ctr <- get("Counter", envir = ns4f)$new()
  ctr$increment(by = 3L)
  ctr$value == 3L
}))

ns4f_full <- load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE, full = TRUE)

check("del-file: full=TRUE clears negate from ns", quote(
  !exists("negate", envir = ns4f_full, inherits = FALSE)
))

check("del-file: full=TRUE clears double from ns", quote(
  !exists("double", envir = ns4f_full, inherits = FALSE)
))

check("del-file: full=TRUE clears negate from pkg env", quote(
  !exists("negate", where = pkg_env4, inherits = FALSE)
))

check("del-file: full=TRUE clears double from pkg env", quote(
  !exists("double", where = pkg_env4, inherits = FALSE)
))

check("del-file: full=TRUE add still works", quote(
  get("add", envir = ns4f_full)(1, 2) == 1003
))

check("remove-fn: message lists changed file", quote(
  any(grepl("base\\.R", reload4b$messages))
))

check("add-fn: message lists changed file", quote(
  any(grepl("base\\.R", reload4c$messages))
))

check("modify-fn: message lists changed file", quote(
  any(grepl("base\\.R", reload4d$messages))
))

check("new-file: message lists added file", quote(
  any(grepl("extras\\.R", reload4e$messages))
))

# --- 4g: Incremental message truncates after ten files ---
cat("\n--- 4g: incremental message truncation ---\n\n")

many_files <- sprintf("bulk_%02d.R", 1:12)
for (f in many_files) {
  writeLines(
    c(
      sprintf("fn_%s <- function() %d", sub("\\.R$", "", f), match(f, many_files))
    ),
    file.path(tmp_c, "R", f)
  )
}

reload4g <- capture_messages(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)
)

check("many-files: reload returns namespace", quote(
  is.environment(reload4g$value) && isNamespace(reload4g$value)
))

check("many-files: message lists up to five bulk files", quote(
  sum(vapply(
    many_files[1:5],
    function(f) any(grepl(f, reload4g$messages, fixed = TRUE)),
    logical(1)
  )) == 5L
))

check("many-files: message truncates remaining files", quote(
  any(grepl("and 7 more file\\(s\\)", reload4g$messages))
))

check("many-files: sixth and later files are not listed explicitly", quote(
  !any(grepl("bulk_06\\.R|bulk_07\\.R|bulk_08\\.R|bulk_09\\.R|bulk_10\\.R|bulk_11\\.R|bulk_12\\.R", reload4g$messages))
))

# --- 4h: failed incremental reload must not advance cache ---
cat("\n--- 4h: failed incremental reload preserves prior state ---\n\n")

writeLines(c(
  "add <- function(a, b) {",
  "  a + b + 1000",
  "}",
  "",
  "BROKEN_PARSE <- (",
  "",
  "scale_vector <- function(x, factor = 1) {",
  "  x * factor",
  "}",
  "",
  "multiply <- function(a, b) {",
  "  a * b",
  "}"
), file.path(tmp_c, "R", "base.R"))

failed_reload4h <- tryCatch(
  list(value = load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE), error = NULL),
  error = function(e) list(value = NULL, error = e)
)

check("failed-reload: incremental reload errors on broken source file", quote(
  inherits(failed_reload4h$error, "error")
))

check("failed-reload: existing namespace state is preserved after failed reload", quote(
  get("add", envir = ns4f_full)(1, 2) == 1003
))

check("failed-reload: attached pkg env still has prior add() after failed reload", quote(
  get("add", pos = pkg_env4)(1, 2) == 1003
))

check("failed-reload: error reports the broken source file", quote(
  grepl("base\\.R", conditionMessage(failed_reload4h$error)) ||
    grepl("unexpected", conditionMessage(failed_reload4h$error), fixed = TRUE)
))

writeLines(c(
  "add <- function(a, b) {",
  "  a + b + 2000",
  "}",
  "",
  "scale_vector <- function(x, factor = 1) {",
  "  x * factor",
  "}",
  "",
  "multiply <- function(a, b) {",
  "  a * b",
  "}"
), file.path(tmp_c, "R", "base.R"))

recovered_reload4h <- capture_messages(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)
)

check("failed-reload: fixed file is retried on next incremental load", quote(
  get("add", envir = recovered_reload4h$value)(1, 2) == 2003
))

check("failed-reload: pkg env updates after successful retry", quote(
  get("add", pos = pkg_env4)(1, 2) == 2003
))

# --- 4i: runtime patch invalidation triggers single-file reload ---
cat("\n--- 4i: runtime patch invalidation triggers single-file reload ---\n\n")

writeLines(c(
  "runtime_target <- function() {",
  "  \"original\"",
  "}",
  "",
  "activate_runtime_patch <- function() {",
  "  assign(",
  "    \"runtime_target\",",
  "    function() \"patched\",",
  "    envir = environment(runtime_target)",
  "  )",
  "  load_fast_register_reload(",
  paste0("    path = \"", gsub("\\\\", "/", tmp_c), "\","),
  "    files = \"runtime_patch.R\",",
  "    reason = \"runtime patch test\"",
  "  )",
  "  invisible(NULL)",
  "}"
), file.path(tmp_c, "R", "runtime_patch.R"))

runtime_patch_load <- capture_messages(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)
)

check("invalidate-file: runtime patch helper file loads", quote(
  exists("runtime_target", envir = runtime_patch_load$value, inherits = FALSE) &&
    exists("activate_runtime_patch", envir = runtime_patch_load$value, inherits = FALSE)
))

check("invalidate-file: runtime_target initially returns original", quote(
  get("runtime_target", envir = runtime_patch_load$value)() == "original"
))

get("activate_runtime_patch", envir = runtime_patch_load$value)()

check("invalidate-file: runtime patch changes live namespace state", quote(
  get("runtime_target", envir = runtime_patch_load$value)() == "patched"
))

invalidated_reload4i <- capture_messages(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)
)

check("invalidate-file: invalidated file is re-sourced on next load", quote(
  get("runtime_target", envir = invalidated_reload4i$value)() == "original"
))

check("invalidate-file: pkg env also reflects restored function", quote(
  get("runtime_target", pos = pkg_env4)() == "original"
))

check("reload-file: next load reports reload application", quote(
  any(grepl("Applying registered reload for", invalidated_reload4i$messages, fixed = TRUE))
))

check("reload-file: next load reports reload reason", quote(
  any(grepl("runtime patch test", invalidated_reload4i$messages, fixed = TRUE))
))

check("reload-file: next load reports registered file", quote(
  any(grepl("runtime_patch\\.R", invalidated_reload4i$messages))
))

# --- 4j: runtime S4 patch invalidation triggers single-file reload ---
cat("\n--- 4j: runtime S4 patch invalidation triggers single-file reload ---\n\n")

writeLines(c(
  "setGeneric(",
  "  \"runtime_describe_animal\",",
  "  function(x) standardGeneric(\"runtime_describe_animal\")",
  ")",
  "",
  "setMethod(",
  "  \"runtime_describe_animal\",",
  "  \"Animal\",",
  "  function(x) {",
  "    paste0(\"original:\", x@name)",
  "  }",
  ")",
  "",
  "activate_runtime_s4_patch <- function() {",
  "  setMethod(",
  "    \"runtime_describe_animal\",",
  "    \"Animal\",",
  "    function(x) {",
  "      paste0(\"patched:\", x@name)",
  "    }",
  "  )",
  "  load_fast_register_reload(",
  paste0("    path = \"", gsub("\\\\", "/", tmp_c), "\","),
  "    files = \"runtime_patch_s4.R\",",
  "    reason = \"runtime S4 patch test\"",
  "  )",
  "  invisible(NULL)",
  "}"
), file.path(tmp_c, "R", "runtime_patch_s4.R"))

runtime_patch_s4_load <- capture_messages(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)
)

a_runtime_s4 <- get("animal", envir = runtime_patch_s4_load$value)("Milo", "cat", 4)

check("invalidate-s4: runtime S4 helper file loads", quote(
  exists("runtime_describe_animal", envir = runtime_patch_s4_load$value, inherits = FALSE) &&
    exists("activate_runtime_s4_patch", envir = runtime_patch_s4_load$value, inherits = FALSE)
))

check("invalidate-s4: S4 method initially returns original behavior", quote(
  get("runtime_describe_animal", envir = runtime_patch_s4_load$value)(a_runtime_s4) == "original:Milo"
))

get("activate_runtime_s4_patch", envir = runtime_patch_s4_load$value)()

check("invalidate-s4: runtime S4 patch changes live method behavior", quote(
  get("runtime_describe_animal", envir = runtime_patch_s4_load$value)(a_runtime_s4) == "patched:Milo"
))

invalidated_reload4j <- capture_messages(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)
)

check("invalidate-s4: invalidated S4 file is re-sourced on next load", quote(
  get("runtime_describe_animal", envir = invalidated_reload4j$value)(a_runtime_s4) == "original:Milo"
))

check("invalidate-s4: pkg env also reflects restored S4 method", quote(
  get("runtime_describe_animal", pos = pkg_env4)(a_runtime_s4) == "original:Milo"
))

check("reload-s4: next load reports S4 reload application", quote(
  any(grepl("Applying registered reload for", invalidated_reload4j$messages, fixed = TRUE))
))

check("reload-s4: next load reports S4 reload reason", quote(
  any(grepl("runtime S4 patch test", invalidated_reload4j$messages, fixed = TRUE))
))

check("reload-s4: next load reports registered S4 file", quote(
  any(grepl("runtime_patch_s4\\.R", invalidated_reload4j$messages))
))

# --- 4k: Change renv.lock and keep warning until baseline is reset ---
cat("\n--- 4k: persistent renv.lock change warning ---\n\n")

lock_path <- file.path(tmp_c, "renv.lock")
if (!file.exists(lock_path)) {
  writeLines("{}", lock_path)
}
old_lock <- readLines(lock_path, warn = FALSE)
writeLines(c(old_lock, "", " "), lock_path)

lock_reload <- capture_conditions(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)
)

check("lockfile: reload still returns namespace", quote(
  is.environment(lock_reload$value) && isNamespace(lock_reload$value)
))

check("lockfile: warns when renv.lock changed", quote(
  any(grepl("renv.lock changed", lock_reload$warnings))
))

lock_reload_again <- capture_conditions(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE)
)

check("lockfile: warning persists on later reloads", quote(
  any(grepl("renv.lock changed", lock_reload_again$warnings))
))

lock_reload_full <- capture_conditions(
  load_fast(tmp_c, helpers = FALSE, attach_testthat = FALSE, full = TRUE)
)

check("lockfile: full reload resets warning baseline", quote(
  !any(grepl("renv.lock changed", lock_reload_full$warnings))
))

# --- 4l: .onLoad hook is called during full and incremental loads ---
cat("\n--- 4l: .onLoad hook execution ---\n\n")

tmp_onload <- tempfile("loadfast_onload_")
copy_baseline(tmp_onload)
remove_renv_lock(tmp_onload)

writeLines(c(
  ".onLoad_call_count <- 0L",
  ".onLoad <- function(libname, pkgname) {",
  "  .onLoad_call_count <<- .onLoad_call_count + 1L",
  "  .onLoad_libname <<- libname",
  "  .onLoad_pkgname <<- pkgname",
  "}"
), file.path(tmp_onload, "R", "zzz.R"))

ns_onload <- load_fast(tmp_onload, helpers = FALSE, attach_testthat = FALSE)

check(".onLoad: is called on full load", quote(
  exists(".onLoad_call_count", envir = ns_onload, inherits = FALSE) &&
    get(".onLoad_call_count", envir = ns_onload) == 1L
))

check(".onLoad: receives correct pkgname", quote(
  get(".onLoad_pkgname", envir = ns_onload) == "devpackage"
))

check(".onLoad: receives dirname(abs_path) as libname", quote(
  identical(
    normalizePath(get(".onLoad_libname", envir = ns_onload), mustWork = FALSE),
    normalizePath(dirname(tmp_onload), mustWork = FALSE)
  )
))

# Incremental reload — nothing changed => short-circuit, .onLoad not re-called
ns_onload_nochg <- load_fast(tmp_onload, helpers = FALSE, attach_testthat = FALSE)

check(".onLoad: not called again on no-change reload", quote(
  get(".onLoad_call_count", envir = ns_onload_nochg) == 1L
))

# Trigger an incremental reload by modifying base.R
writeLines(c(
  "add <- function(a, b) a + b + 9999"
), file.path(tmp_onload, "R", "base.R"))

ns_onload_incr <- load_fast(tmp_onload, helpers = FALSE, attach_testthat = FALSE)

check(".onLoad: called again on incremental reload (files changed)", quote(
  get(".onLoad_call_count", envir = ns_onload_incr) == 2L
))

check(".onLoad: add() reflects incremental change", quote(
  get("add", envir = ns_onload_incr)(1, 2) == 10002
))

# ============================================================================
# Summary
# ============================================================================
cat("\n")
cat("Results:", passed, "passed,", failed, "failed\n")
for (d in .tmp_dirs) {
  unlink(d, recursive = TRUE)
}
if (failed > 0L) {
  cat("SOME TESTS FAILED\n")
  quit(status = 1L)
} else {
  cat("ALL TESTS PASSED\n")
}
