# Self-contained checks that run against the *installed* package during
# R CMD check. The exhaustive suite (multi-package fidelity, S3/S4/R6 fixtures,
# incremental edge cases) lives in test_loadfast.R at the repository root.

write_mini_pkg <- function(name, fn_body = 'mini_fn <- function() "v1"',
                           ns_lines = "export(mini_fn)", desc_extra = character(0)) {
  root <- file.path(tempfile("loadfast_tt_"), name)
  dir.create(file.path(root, "R"), recursive = TRUE)
  writeLines(
    c(paste0("Package: ", name), "Title: t", "Version: 0.0.1",
      "Description: d.", "License: MIT + file LICENSE", desc_extra),
    file.path(root, "DESCRIPTION")
  )
  writeLines(ns_lines, file.path(root, "NAMESPACE"))
  writeLines(fn_body, file.path(root, "R", "fns.R"))
  root
}

cleanup_pkg <- function(name, root) {
  pkg_env <- paste0("package:", name)
  if (pkg_env %in% search()) {
    detach(pkg_env, character.only = TRUE, unload = FALSE, force = TRUE)
  }
  if (name %in% loadedNamespaces()) {
    try(unloadNamespace(name), silent = TRUE)
  }
  unlink(dirname(root), recursive = TRUE)
}

test_that("load_fast() performs a full load and registers a working namespace", {
  root <- write_mini_pkg("ttminia")
  on.exit(cleanup_pkg("ttminia", root))

  ns <- suppressMessages(load_fast(root, helpers = FALSE, attach_testthat = FALSE))

  expect_true(isNamespace(ns))
  expect_true("ttminia" %in% loadedNamespaces())
  expect_true("package:ttminia" %in% search())
  expect_identical(get("mini_fn", envir = ns)(), "v1")
  expect_identical(getExportedValue("ttminia", "mini_fn")(), "v1")
})

test_that("load_fast() reloads changed files incrementally", {
  root <- write_mini_pkg("ttminib")
  on.exit(cleanup_pkg("ttminib", root))

  ns <- suppressMessages(load_fast(root, helpers = FALSE, attach_testthat = FALSE))
  expect_identical(get("mini_fn", envir = ns)(), "v1")

  writeLines('mini_fn <- function() "v2"', file.path(root, "R", "fns.R"))
  expect_message(
    ns2 <- load_fast(root, helpers = FALSE, attach_testthat = FALSE),
    "Incremental reload"
  )
  expect_identical(ns2, ns)
  expect_identical(get("mini_fn", envir = ns2)(), "v2")

  expect_message(
    load_fast(root, helpers = FALSE, attach_testthat = FALSE),
    "No changes"
  )
})

test_that("importing packages are flagged for a full reload when a dependency reloads", {
  root_a <- write_mini_pkg("ttdepa", fn_body = 'dep_fn <- function() "a1"',
                           ns_lines = "export(dep_fn)")
  root_b <- write_mini_pkg("ttdepb",
                           fn_body = 'use_dep <- function() paste0("b:", dep_fn())',
                           ns_lines = c("importFrom(ttdepa, dep_fn)", "export(use_dep)"))
  on.exit({
    cleanup_pkg("ttdepb", root_b)
    cleanup_pkg("ttdepa", root_a)
  })

  suppressMessages(load_fast(root_a, helpers = FALSE, attach_testthat = FALSE))
  ns_b <- suppressMessages(load_fast(root_b, helpers = FALSE, attach_testthat = FALSE))
  expect_identical(get("use_dep", envir = ns_b)(), "b:a1")

  writeLines('dep_fn <- function() "a2"', file.path(root_a, "R", "fns.R"))
  suppressMessages(load_fast(root_a, helpers = FALSE, attach_testthat = FALSE))

  expect_message(
    ns_b2 <- load_fast(root_b, helpers = FALSE, attach_testthat = FALSE),
    "Full reload of 'ttdepb'"
  )
  expect_identical(get("use_dep", envir = ns_b2)(), "b:a2")
})

test_that("load_fast() rejects paths outside a package", {
  bare <- tempfile("loadfast_bare_")
  dir.create(bare)
  on.exit(unlink(bare, recursive = TRUE))

  expect_error(load_fast(bare), "Could not find package root")
  expect_error(load_fast(file.path(bare, "nope")), "No such file|cannot be found|does not exist")
})

test_that("load_fast() validates the DESCRIPTION Package field", {
  root <- write_mini_pkg("ttminic")
  on.exit(unlink(dirname(root), recursive = TRUE))
  writeLines(c("Title: t", "Version: 0.0.1"), file.path(root, "DESCRIPTION"))

  expect_error(
    load_fast(root, helpers = FALSE, attach_testthat = FALSE),
    "No valid 'Package' field"
  )
})

test_that("load_fast_register_reload() validates its inputs", {
  expect_error(load_fast_register_reload(files = character(0)), "at least one path")

  root <- write_mini_pkg("ttminid")
  on.exit(cleanup_pkg("ttminid", root))
  suppressMessages(load_fast(root, helpers = FALSE, attach_testthat = FALSE))

  expect_error(
    load_fast_register_reload(root, files = file.path(tempdir(), "elsewhere.R")),
    "No such file|cannot be found|must be inside"
  )

  expect_message(
    result <- load_fast_register_reload(root, files = "fns.R", reason = "test"),
    "Registered file"
  )
  expect_true(result)
  expect_message(
    load_fast(root, helpers = FALSE, attach_testthat = FALSE),
    "Applying registered reload"
  )
})

test_that("a broken source file fails cleanly and recovery works", {
  root <- write_mini_pkg("ttminie")
  on.exit(cleanup_pkg("ttminie", root))

  suppressMessages(load_fast(root, helpers = FALSE, attach_testthat = FALSE))
  writeLines('mini_fn <- function() "broken" (', file.path(root, "R", "fns.R"))
  expect_error(
    suppressMessages(load_fast(root, helpers = FALSE, attach_testthat = FALSE, full = TRUE)),
    "Failed to source"
  )
  expect_false("ttminie" %in% loadedNamespaces())

  writeLines('mini_fn <- function() "fixed"', file.path(root, "R", "fns.R"))
  ns <- suppressMessages(load_fast(root, helpers = FALSE, attach_testthat = FALSE))
  expect_identical(get("mini_fn", envir = ns)(), "fixed")
})
