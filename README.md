# loadfast

Standalone, single-file replacement for `devtools::load_all()` with MD5-based incremental reloading. No runtime dependency on pkgload or devtools — just `rlang`.

The canonical source lives at `https://github.com/finccam-com/loadfast/`.

`loadfast.R` is intended to be copied and pasted into each repo that uses it. If you want to change the loader, make the change in this source repo first, then copy-paste the updated file into downstream repos.

## Recommended setup

1. Copy-paste `loadfast.R` into the root of the repo where you want to use it.

2. Add this guard to `.Rprofile` so `loadfast` is opt-in:

```r
if (identical(Sys.getenv("FINCCAM_LOADFAST_ENABLED"), "true")) {
  source("loadfast.R")
}
```

## Usage

```r
source("loadfast.R")
load_fast("path/to/your/package")
```

`load_fast()` reads the package name from `DESCRIPTION`, builds a proper namespace (so S4 and R6 work), processes `NAMESPACE` imports, sources `R/*.R`, attaches the package to the search path, and optionally sources testthat helpers.

On the first call for a given package path it does a full teardown+rebuild. On subsequent calls for that same path it re-sources only files whose MD5 hash changed.

`load_fast()` also accepts:

- `helpers = TRUE` to source `helper*.R` files from `tests/testthat/` when testthat is available
- `attach_testthat = NULL` to auto-detect whether `testthat` should be attached
- `full = TRUE` to force a complete teardown+rebuild
- `verbose = TRUE` to emit per-phase timing logs

If runtime code needs a specific file to be re-sourced on the next load, call `load_fast_register_reload()` to register that file for reload. This is useful for cases like runtime patching or temporary method overrides.

If `renv.lock` changes between incremental loads for the same package path, `load_fast()` warns. Dependency changes may require restarting R or reinstalling packages.

Re-sourcing `loadfast.R` itself resets the in-memory loader state, so the next `load_fast()` call will be a full load.

## Important limitation: incremental reload does not clean up stale symbols

For performance, the incremental path does **not** track which symbols came from which file and does **not** remove stale objects when files are deleted or functions are removed.

This is a conscious tradeoff, not a claim that cleanup is impossible in principle. We have not found a performant enough implementation yet for the large-project use case `loadfast` targets. Approaches based on per-file symbol diffing and repeated enumeration of large namespaces were too slow.

This means that after an incremental reload:

- deleted files can leave old objects behind
- removed variables or functions can remain available in the loaded package until you force a full rebuild

Pass `full = TRUE` to force a complete teardown+rebuild. You should do this after deleting files, removing functions, or whenever you need a clean namespace state.

## Tests

Run all tests:

```sh
Rscript test_loadfast.R
```
