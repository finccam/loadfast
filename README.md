# loadfast

Standalone, single-file replacement for `devtools::load_all()` with MD5-based incremental reloading. No dependency on pkgload or devtools — just `rlang`.

## Usage

```r
source("loadfast.R")
load_fast("path/to/your/package")
```

`load_fast()` reads the package name from `DESCRIPTION`, builds a proper namespace (S4/R6 work), processes `NAMESPACE` imports, sources `R/*.R`, attaches to the search path, and optionally loads testthat helpers.

On first call it does a full teardown+rebuild. On subsequent calls for the same path it re-sources only files whose MD5 hash changed. Pass `full = TRUE` to force a complete rebuild (needed after deleting files or removing functions).

### loadfast_v1

`loadfast_v1.R` is the initial implementation without incremental reload support — it always does a full teardown+rebuild on every call. Superseded by `loadfast.R`.

```r
source("loadfast_v1.R")
loadfast_v1("path/to/your/package")
```

## Tests

```sh
cd loadfast
Rscript test_loadfast.R
Rscript test_loadfast_v1.R
```
