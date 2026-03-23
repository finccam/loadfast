# loadfast

Standalone, single-file replacement for `devtools::load_all()` with MD5-based incremental reloading. No dependency on pkgload or devtools — just `rlang`.

The canonical source lives at `https://github.com/finccam-com/loadfast/`.

`loadfast.R` is intended to be copied and pasted into each repo that uses it. If you want to change the loader, make the change in this source repo first, then copy-paste the updated file into downstream repos.

## Usage

```r
source("loadfast.R")
load_fast("path/to/your/package")
```

`load_fast()` reads the package name from `DESCRIPTION`, builds a proper namespace (S4/R6 work), processes `NAMESPACE` imports, sources `R/*.R`, attaches to the search path, and optionally loads testthat helpers.

On first call it does a full teardown+rebuild. On subsequent calls for the same path it re-sources only files whose MD5 hash changed. Pass `full = TRUE` to force a complete rebuild (needed after deleting files or removing functions).

If runtime code needs a specific file to be re-sourced on the next load, call `load_fast_register_reload()` to register that file for reload. This is useful for cases like runtime patching or temporary method overrides.

If `renv.lock` changes between incremental loads for the same package path, `load_fast()` warns. Dependency changes may require restarting R or reinstalling packages.

## Recommended setup

1. Copy-paste `loadfast.R` into the root of the repo where you want to use it.

2. Add this guard to `.Rprofile` so `loadfast` is opt-in:

```r
if (identical(Sys.getenv("FINCCAM_LOADFAST_ENABLED"), "true")) {
  source("loadfast.R")
}
```

## Tests

Use the single entry-point test script:

```sh
cd loadfast
Rscript test_loadfast.R
```

`test_loadfast.R` is the only test command you should run directly. It sources `loadfast.R` and then sources `run_tests.R`.

`run_tests.R` is the internal unified test suite implementation. It exists to keep the top-level runner small and the full test logic in one place.
