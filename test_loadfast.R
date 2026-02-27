# test_loadfast.R
# Verifies that load_fast() works correctly end-to-end.
# Run from the loadfast/ directory: Rscript test_loadfast.R

passed <- 0L
failed <- 0L

check <- function(description, expr) {
  result <- tryCatch(
    {
      ok <- eval(expr, envir = parent.frame())
      if (isTRUE(ok)) "pass" else paste("FAIL — got", deparse(ok))
    },
    error = function(e) paste("ERROR —", conditionMessage(e))
  )
  if (result == "pass") {
    passed <<- passed + 1L
    cat("[PASS]", description, "\n")
  } else {
    failed <<- failed + 1L
    cat("[FAIL]", description, ":", result, "\n")
  }
}

# --- Load ---
source("loadfast.R")
ns <- load_fast(".")

# --- Test: package name read from DESCRIPTION ---
check("Package name is 'devpackage'", quote(
  ns$.packageName == "devpackage"
))

# --- Test: namespace is registered ---
check("Namespace is registered", quote(
  "devpackage" %in% loadedNamespaces()
))

check("isNamespace() returns TRUE", quote(
  isNamespace(ns)
))

# --- Test: R/script.R was sourced (add function exists) ---
check("add() exists in namespace", quote(
  exists("add", envir = ns, inherits = FALSE)
))

check("add(2, 3) returns 5", quote(
  get("add", envir = ns)(2, 3) == 5
))

check("add(-1, 1) returns 0", quote(
  get("add", envir = ns)(-1, 1) == 0
))

# --- Test: package is attached to the search path ---
check("package:devpackage is on the search path", quote(
  "package:devpackage" %in% search()
))

check("add() is visible from the attached env", quote(
  exists("add", where = "package:devpackage", inherits = FALSE)
))

# --- Test: imports env exists and has correct parent chain ---
impenv <- parent.env(ns)

check("Imports env name is 'imports:devpackage'", quote(
  identical(attr(impenv, "name"), "imports:devpackage")
))

check("Imports env parent is .BaseNamespaceEnv", quote(
  identical(parent.env(impenv), .BaseNamespaceEnv)
))

# --- Test: importFrom(rlang, ns_registry_env) was processed ---
check("ns_registry_env is available via imports env", quote(
  exists("ns_registry_env", envir = impenv, inherits = FALSE)
))

# --- Test: import(methods) was processed ---
check("setClass is available via imports env (from methods)", quote(
  exists("setClass", envir = impenv, inherits = FALSE)
))

check("setMethod is available via imports env (from methods)", quote(
  exists("setMethod", envir = impenv, inherits = FALSE)
))

# --- Test: S4 classes exist ---
check("Animal class is defined", quote(
  isClass("Animal")
))

check("Pet class is defined", quote(
  isClass("Pet")
))

check("Pet extends Animal", quote(
  extends("Pet", "Animal")
))

# --- Test: S4 generics exist ---
check("describe generic exists", quote(
  isGeneric("describe")
))

check("greet generic exists", quote(
  isGeneric("greet")
))

# --- Test: S4 constructors work ---
a <- get("animal", envir = ns)("Rex", "dog", 4)
p <- get("pet", envir = ns)("Milo", "cat", 4, "Alice")

check("animal() returns an Animal instance", quote(
  is(a, "Animal")
))

check("pet() returns a Pet instance", quote(
  is(p, "Pet")
))

check("Pet instance is also an Animal", quote(
  is(p, "Animal")
))

# --- Test: S4 slots ---
check("Animal@name is correct", quote(
  a@name == "Rex"
))

check("Animal@species is correct", quote(
  a@species == "dog"
))

check("Animal@legs is correct", quote(
  a@legs == 4
))

check("Pet@owner is correct", quote(
  p@owner == "Alice"
))

# --- Test: S4 methods dispatch correctly ---
check("describe(Animal) works", quote(
  get("describe", envir = ns)(a) == "Rex is a dog with 4 legs"
))

check("describe(Pet) includes owner (callNextMethod)", quote(
  get("describe", envir = ns)(p) == "Milo is a cat with 4 legs, owned by Alice"
))

check("greet(Pet) works", quote(
  get("greet", envir = ns)(p) == "Hello! My name is Milo and I belong to Alice"
))

# --- Test: reload works (no errors on second load) ---
ns2 <- load_fast(".")

check("Reload succeeds and returns a namespace", quote(
  isNamespace(ns2)
))

check("add() still works after reload", quote(
  get("add", envir = ns2)(10, 20) == 30
))

# --- Summary ---
cat("\n")
cat("Results:", passed, "passed,", failed, "failed\n")
if (failed > 0L) {
  cat("SOME TESTS FAILED\n")
  quit(status = 1L)
} else {
  cat("ALL TESTS PASSED\n")
}