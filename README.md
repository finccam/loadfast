# loadfast

Standalone, single-file replacement for `devtools::load_all()`. No dependency on pkgload or devtools — just `rlang`.

## Usage

```r
source("loadfast.R")
load_fast("path/to/your/package")
```

`load_fast()` reads the package name from `DESCRIPTION`, builds a proper namespace (S4/R6 work), processes `NAMESPACE` imports, sources `R/*.R`, attaches to the search path, and optionally loads testthat helpers.

## Tests

```sh
cd loadfast
Rscript test_loadfast.R
```
