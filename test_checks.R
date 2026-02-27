passed <- 0L
failed <- 0L

check <- function(description, expr) {
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

# ============================================================================
# STAGE 1: Load project1
# ============================================================================
cat("\n--- Stage 1: load project1 ---\n\n")

ns <- load_fast("project1")

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

check("Logger entries are plain (no level prefix in project1)", quote(
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

# --- Run testthat suite for project1 ---
cat("\n--- Running testthat::test_dir() for project1 ---\n\n")
tt_results1 <- testthat::test_dir(
  file.path("project1", "tests", "testthat"),
  env = as.environment("package:devpackage"),
  stop_on_failure = FALSE
)
tt_df1 <- as.data.frame(tt_results1)
n_tt_fail1 <- sum(tt_df1$failed)
n_tt_pass1 <- sum(tt_df1$passed)

check("testthat project1: all tests pass", quote(
  n_tt_fail1 == 0L
))

cat(sprintf("  (testthat project1: %d passed, %d failed)\n", n_tt_pass1, n_tt_fail1))

# ============================================================================
# STAGE 2: Reload with project2 (same package name, changed code)
# ============================================================================
cat("\n--- Stage 2: reload with project2 ---\n\n")

ns2 <- load_fast("project2")

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

# --- mutate_dt: project2 adds a rank column ---
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

# --- speak() is new in project2 ---
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

check("Logger$format_entries() is new in project2", quote(
  !is.null(lg2$format_entries) && lg2$format_entries() == "[WARN] problem\n[WARN] another"
))

ctr2 <- get("Counter", envir = ns2)$new(10L)

check("Counter$new(10) starts at 10", quote(
  ctr2$value == 10L
))

ctr2$decrement(by = 3L)

check("Counter$decrement() is new in project2", quote(
  ctr2$value == 7L
))

# --- testthat helpers updated after reload ---
th_animal2 <- get("make_test_animal", pos = "package:devpackage")()
th_logger2 <- get("make_test_logger", pos = "package:devpackage")()

check("make_test_animal() returns updated Animal", quote(
  is(th_animal2, "Animal") && th_animal2@name == "TestAnimal2"
))

check("make_test_animal() Animal has age slot from project2", quote(
  th_animal2@age == 2
))

check("make_test_logger() now uses DEBUG level", quote(
  th_logger2$level == "DEBUG"
))

check("make_test_logger() entry is prefixed with level", quote(
  th_logger2$last() == "[DEBUG] init"
))

# --- Run testthat suite for project2 ---
cat("\n--- Running testthat::test_dir() for project2 ---\n\n")
tt_results2 <- testthat::test_dir(
  file.path("project2", "tests", "testthat"),
  env = as.environment("package:devpackage"),
  stop_on_failure = FALSE
)
tt_df2 <- as.data.frame(tt_results2)
n_tt_fail2 <- sum(tt_df2$failed)
n_tt_pass2 <- sum(tt_df2$passed)

check("testthat project2: all tests pass", quote(
  n_tt_fail2 == 0L
))

cat(sprintf("  (testthat project2: %d passed, %d failed)\n", n_tt_pass2, n_tt_fail2))

