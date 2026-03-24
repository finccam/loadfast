# loadfast

`loadfast` is an installable R package that aims to be a drop-in replacement for `devtools::load_all()` for large codebases, with MD5-based incremental reloading to speed up the edit-reload-test loop.

`loadfast` is meant to improve the development loop for large packages, not to be a general replacement for all `devtools::load_all()` workflows. See [Important limitation: incremental reload does not clean up stale symbols](#important-limitation-incremental-reload-does-not-clean-up-stale-symbols) below for the main tradeoff.

It does not depend on `pkgload` or `devtools` at runtime. The main runtime dependency is `rlang`.

## Installation

Install from GitHub with either `pak` or `remotes`:

```r
pak::pkg_install("finccam/loadfast")
# or
remotes::install_github("finccam/loadfast")
```

## Usage

Call `load_fast()` on a package root:

```r
loadfast::load_fast()
# or
loadfast::load_fast("path/to/your/package")
```

`load_fast()` reads the package name from `DESCRIPTION`, builds a proper namespace (so S4 and R6 work), processes `NAMESPACE` imports, sources `R/*.R`, attaches the package to the search path, and optionally sources testthat helpers.

It is designed for the common development workflow where you repeatedly edit source files and reload the same package. On the first call for a given package path it does a full teardown+rebuild. On subsequent calls for that same path it re-sources only files whose MD5 hash changed.

`load_fast()` also accepts:

- `helpers = TRUE` to source `helper*.R` files from `tests/testthat/` when testthat is available
- `attach_testthat = NULL` to auto-detect whether `testthat` should be attached
- `full = TRUE` to force a complete teardown+rebuild
- `verbose = TRUE` to emit per-phase timing logs

If runtime code needs a specific file to be re-sourced on the next load, call `load_fast_register_reload()` to register that file for reload. This is useful for cases like runtime patching or temporary method overrides.

If `renv.lock` changes between incremental loads for the same package path, `load_fast()` warns. Dependency changes may require restarting R or reinstalling packages.

Reloading the `loadfast` package itself resets the in-memory loader state, so the next `load_fast()` call will be a full load.

## Important limitation: incremental reload does not clean up stale symbols

For performance, the incremental path does **not** track which symbols came from which file and does **not** remove stale objects when files are deleted or functions are removed.

This is a conscious tradeoff, not a claim that cleanup is impossible in principle. We have not found a performant enough implementation yet for the large-project use case `loadfast` targets. Approaches based on per-file symbol diffing and repeated enumeration of large namespaces were too slow.

This means that after an incremental reload:

- deleted files can leave old objects behind
- removed variables or functions can remain available in the loaded package until you force a full rebuild

Pass `full = TRUE` to force a complete teardown+rebuild. You should do this after deleting files, removing functions, or whenever you need a clean namespace state.

## RStudio addin

`loadfast` can expose an RStudio addin so you can bind `load_fast()` to a keyboard shortcut in the IDE once the package is installed.

## Tests

The repo currently keeps its own custom test harness.

Run all tests with:

```sh
Rscript test_loadfast.R
```
