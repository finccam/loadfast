# test_loadfast.R
# Verifies that load_fast() works correctly end-to-end, including reload
# with changed code across two project snapshots.
# Run from the loadfast/ directory: Rscript test_loadfast.R

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

source("loadfast.R")

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

check("setMethod is in imports env (from methods)", quote(
  exists("setMethod", envir = impenv, inherits = FALSE)
))

# --- add() from R/script.R ---
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

# --- add() changed behavior ---
check("add(2, 3) now returns 105", quote(
  get("add", envir = ns2)(2, 3) == 105
))

check("add(0, 0) now returns 100", quote(
  get("add", envir = ns2)(0, 0) == 100
))

check("add(-1, 1) now returns 100", quote(
  get("add", envir = ns2)(-1, 1) == 100
))

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