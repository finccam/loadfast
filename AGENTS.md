# AGENTS.md — Non-obvious context for working in this repo

# Hygiene

This `AGENT.md` file is read by every agent session. !!!Keep them high-signal!!! (delete obvious information)

# Coding guidelines

* Do not write organizational or comments that summarize the code. Comments should only be written in order to explain "why" the code is written in some way in the case there is a reason that is tricky / non-obvious.
* Prefer implementing functionality in existing files unless it is a new logical component. Avoid creating many small files.

## Project layout

- This repo **is** the source-of-truth edit target for the `loadfast` package. If you are changing loader behavior, docs, or tests for `loadfast`, make the change here.
- **`R/loadfast.R`** contains the canonical loader implementation exported by the package. It provides MD5-based incremental reloading: on first call it does a full teardown+rebuild; on subsequent calls for the same path it re-sources only files whose MD5 hash changed. See "Incremental loader" section below.
- **`DESCRIPTION`**, **`NAMESPACE`**, and **`inst/rstudio/addins.dcf`** define the installable package and its RStudio addin registration.
- **`test_loadfast.R`** is the top-level custom test runner. Keep this as the single command users run.
- **`devpackage/`** is the single frozen baseline package snapshot used by the tests. Contains `DESCRIPTION`, `NAMESPACE`, `R/` (source files), and `tests/testthat/` (testthat tests + helpers). Package name is `devpackage`. All code mutations for reload/incremental testing are applied ad-hoc to temp copies at test time.
  - `R/base.R` — plain functions (`add`, `scale_vector`, `summarize_values`, `mutate_dt`) — `mutate_dt` exercises `data.table`'s `:=` and `as.data.table` via `importFrom`
  - `R/s4_classes.R` — S4 classes (`Animal`, `Pet`), generics, methods
  - `R/r6_classes.R` — R6 classes (`Logger`, `Counter`)
  - `tests/testthat/helper-utils.R` — testthat helper factories (`make_test_animal`, `make_test_logger`)
  - `tests/testthat/test-base.R` — testthat tests exercising all of the above
- **`renv/`** and **`renv.lock`** manage the project-local library. Key packages: `testthat`, `R6`, `rlang`, `data.table`.
- **`TECHNICAL_DEBT.md`** tracks known loader tradeoffs, risks, and cleanup opportunities. Update it when you identify a non-trivial issue that is worth preserving across sessions. Use reload-registration terminology in docs and guidance rather than cache-invalidation terminology when describing the user-facing behavior.
- **`pkgload/`** and **`devtools`** contains the original pkgload & devtools R package source code (moved here for reference). It is NOT used at runtime (and gitignored). Can be initally cloned with `just setup`.

## Shared design decisions

- The package name is **read from the `Package:` field in DESCRIPTION**. No hard-coding required — just set the field in your DESCRIPTION file.
- `load_fast(path)` takes a **path to a package root** (a directory containing `DESCRIPTION`, `NAMESPACE`, and `R/`). It does not assume `.`.
- Requires **`rlang`** as a runtime dependency (for `rlang::ns_registry_env()`). The user already has it because they use devtools.
- DESCRIPTION is parsed only for the `Package:` field. Imports are read from the **NAMESPACE** file.
- `load_fast()` accepts `helpers` and `attach_testthat` parameters (mirroring pkgload's `load_all`). When `helpers = TRUE` (the default) and testthat is available, it calls `testthat::source_test_helpers()` to source `helper*.R` files from `tests/testthat/` into the attached package environment — the same behavior as pkgload.
- `attach_testthat` defaults to auto-detect: if `tests/testthat/` (or `inst/tests/`) exists and testthat is installed, testthat is attached to the search path via `library("testthat")`.
- **`full = FALSE`** (default): allows incremental reloads. Pass `full = TRUE` to force a complete teardown+rebuild, which is needed to clean up symbols from deleted files or removed functions.
- **`verbose = FALSE`** (default): pass `verbose = TRUE` to emit per-phase timing logs (e.g. `[load_fast] source 475 files  7.210s (cumul 7.510s)`). Useful for diagnosing performance.

## Incremental loader (`R/loadfast.R`)

- **`.loadfast.cache`** is a module-level environment (`parent = emptyenv()`) keyed by `normalizePath(path)`. Each entry currently stores the namespace env, file hashes, `renv.lock` hash baseline, any registered reload files, and the pending reload message to emit on the next load.
- **Change detection**: `tools::md5sum()` on all `R/*.R` files every call. Compared against cached hashes to classify files as changed or added.
- **No per-file symbol tracking**: the incremental path does **not** track which symbols came from which file, and does **not** remove stale symbols when files are deleted or functions are removed. This avoids the O(n²) `ls()` overhead that dominated load time (27.5s of 33.6s in a 475-file project). Stale symbols linger until the user calls `load_fast(path, full = TRUE)`.
- **Package env sync**: after incremental re-sourcing, all symbols from `ns_env` are bulk-copied to the `package:pkg` environment (one `ls()` call total).
- **Testthat helpers**: always re-sourced on every call (simple approach — there are usually only 1-2 helper files).
- **Explicit file reload registration**: runtime code can register one or more files to be reloaded on the next `load_fast()` call. In user-facing docs and messages, describe this as registering or applying a reload, not as cache invalidation.
- **Reloading the `loadfast` package code** recreates `.loadfast.cache`, losing all cached state. The next `load_fast()` call will do a full load. This is intentional during development.
- **`full = TRUE`** bypasses the cache lookup, forcing a full teardown+rebuild. Use this after deleting files or removing functions.

## Testing gotchas

- The `check()` helper wraps test expressions in `quote()` and evaluates with `eval(..., envir = parent.frame())`. Without `quote()`, errors from the assertion itself would escape `tryCatch`.
- `testthat::test_dir()` runs only once (Stage 1, against the frozen `devpackage/` snapshot). Subsequent stages verify behavior via `check()` assertions, which already cover everything the testthat suite tests.
- **`on.exit()` cannot be used at the top level of `run_tests.R`** because it is `source()`'d from a wrapper script. Inside `source()`, `on.exit()` registers on the `eval()` frame which exits immediately, causing premature cleanup. Temp directories are instead tracked in `.tmp_dirs` and cleaned up explicitly at the end of the file.
- **Test stages** (all in `run_tests.R`):
  - **Stage 1**: Load frozen `devpackage/` from its original location. Full checks (namespace, imports, S4, R6, data.table, testthat helpers) + `test_dir()` run.
  - **Stage 2**: Copy `devpackage/` to a temp dir, apply mutations via `writeLines()` (changed function behavior, new S4 slots, new R6 methods, updated testthat helpers), load, verify all changed behavior. The mutations change behavior across all three class systems (plain functions, S4, R6) so the reload path is exercised for each.
  - **Stage 3**: Copy `devpackage/` to a second temp dir, test cross-file dependencies:
    - 3a: `compute()` in `wrappers.R` calls `add()` from `base.R` — change only `base.R`, verify `compute()` output changes.
    - 3b: `describe_loud()` in `wrappers.R` calls `describe()` generic from `s4_classes.R` — change only the method, verify `describe_loud()` output changes. Also tests `callNextMethod` chain for `Pet`.
    - 3c: `make_animal()` in `wrappers.R` calls `new("Animal",...)` — add `age` slot to the class in `s4_classes.R`, verify the unchanged constructor returns an object with the new slot.
    - 3d: add a `Collate` field plus deliberately misordered filenames, then verify the loader respects `Collate` ordering rather than plain alphabetical order.
  - **Stage 4**: Copy `devpackage/` to a third temp dir, test incremental-specific behaviors: no-change short-circuit, function removal (stale symbols linger), function addition, function modification, new file, file deletion, explicit file reload registration, failed incremental reload recovery, runtime S4 method patch reload registration, and persistent `renv.lock` change warnings. Verifies that `full = TRUE` properly cleans up stale symbols.
- Stage 2 always triggers a full load (different path from Stage 1 = cache miss). Stage 3 exercises the incremental path for `load_fast()` on a stable temp path while mutating files in place.

## R namespace machinery gotchas

### A plain `new.env()` is not enough for S4
S4's `setClass`/`setMethod` rely on `topenv()` and `isNamespace()` internally. A plain `new.env(parent = globalenv())` will NOT be recognized as a namespace. You must:
1. Create the proper env chain: `<namespace:pkg>` → `<imports:pkg>` → `.BaseNamespaceEnv`
2. Set up `.__NAMESPACE__.` metadata environment with `spec`, `exports`, `imports`, etc.
3. **Register the env in R's internal namespace registry** so `isNamespace()` returns `TRUE`.

R's `registerNamespace` is an `.Internal` and cannot be called from user code. The workaround is `rlang::ns_registry_env()` which returns the registry as an R environment — you can assign directly into it: `reg[[pkg_name]] <- ns_env`.

### `makeNamespace` is not exported
`makeNamespace` is a **local function defined inside `base::loadNamespace`**. It is not accessible directly. pkgload extracts it at load time via AST manipulation (`extract_lang` + `modify_lang`). In `R/loadfast.R` we instead replicate its logic inline.

### S4 "no definition for class" is a `message()`, not a `warning()`
On R 4.2.2 (and possibly other versions), `methods:::matchSignature` emits the "no definition for class" notice via `message()`, **not** `warning()`. This means `suppressWarnings()` does NOT suppress it — you need `suppressMessages()` or a `withCallingHandlers` that catches **both** `warning` and `message` conditions. This was discovered empirically; the decompiled source appears to show `warning()` but the runtime behavior is `message()`.

These notices are **harmless**. They can still appear when `setMethod()` is sourced before the corresponding `setClass()` because of file ordering. The methods still register correctly. Installed packages never hit this because they load from pre-compiled lazy-load databases (no re-execution of `setClass`/`setMethod`).

### S4 class redefinition on reload requires full unregister
When reloading a package that redefines an S4 class (e.g. adding a slot), the old class definition must be fully evicted first. This works in `R/loadfast.R` because the reload path calls `unloadNamespace()` (or force-removes from the registry), which clears the methods package's internal class cache. Without this, `setClass()` would see the old definition and the new slot would silently fail to appear.

### `parseNamespaceFile` path convention
`parseNamespaceFile(package, package.lib)` constructs the path as `<package.lib>/<package>/NAMESPACE`. So to parse `./NAMESPACE` you must call:
```r
parseNamespaceFile(basename(abs_path), dirname(abs_path))
```
NOT `parseNamespaceFile(pkg_name, ".")` — that would look for `./<pkg_name>/NAMESPACE`.

### `namespaceImport` / `namespaceImportFrom` target the **imports env**
These base R functions place objects into the **parent** of the namespace env (the `imports:<pkg>` env), not into the namespace itself. This is correct R semantics — the namespace inherits from the imports env.

### Imports metadata must be stored in canonical named-list format
`parseNamespaceFile()` returns `$imports` as a flat list of unnamed elements (strings for `import()`, two-element lists for `importFrom()`). But `getNamespaceImports(ns)` consumers — notably **data.table's `cedta()`** — expect a **named list** keyed by package name, where values are `TRUE` (whole-namespace import) or a character vector of symbol names. If you store the raw parse output, `cedta()` won't find `"data.table"` in `names(getNamespaceImports(ns))` and will error with *"environment that is not data.table-aware"* when `:=` is used inside `[.data.table`. The loaders convert to canonical format before calling `setNamespaceInfo(ns_env, "imports", ...)`.

### Imported symbols must be copied to the attached package env
`namespaceImportFrom` places symbols in the imports env (parent of ns_env). Code *inside* the namespace finds them via the parent chain, but they are not in `ls(ns_env)`. To make them available for interactive use on the search path (matching `devtools::load_all()` behavior), the loaders also copy all symbols from the imports env into the `package:` env.

## System-specific notes

- **OS**: Windows
- **R version**: 4.5.2
- **`system.time()` overhead can become surprisingly large when there are ~5000+ names in scope** (for example in a large attached package / namespace such as `finccamengine`). A nested call like `system.time(system.time(1 + 1))` takes about **~0.03s before `load_all()` / `load_fast()`** but can take **~0.5s after loading**. Because the timing function itself becomes expensive in that state, **do not show timings in non-verbose mode**; keep timing output behind `verbose = TRUE`.
- **Multiline `Rscript -e`** commands with heredocs or complex quoting frequently **segfault** on this system. Prefer single-line commands or writing to a temp `.R` file and running `Rscript path/to/file.R`.
- **pkgload and devtools are NOT installed** in the system library, but are available in the renv project library. The renv library also provides testthat, R6, and their dependencies.

## pkgload source code reference (in `pkgload/`)

Key files for understanding the original `load_all` flow:
- `load.R` — main `load_all()` function and orchestration
- `namespace-env.R` — `create_ns_env()`, `makeNamespace` extraction, `register_namespace`, `setup_ns_imports`, `setup_ns_exports`
- `imports-env.R` — `load_imports()`, `process_imports()` (uses AST extraction from `loadNamespace` for the import for-loops)
- `load-code.R` — `load_code()`, `find_code()` (file discovery + Collate field support)
- `source.R` — `source_many()`, `source_one()` (the actual file sourcing with `topLevelEnvironment` option)
- `package-env.R` — `setup_pkg_env()`, `attach_ns()`, `populate_pkg_env()` (attaching to search path)
- `unload.R` — `unload()`, `unregister()`, namespace cleanup
- `file-cache.R` — MD5-based change detection (`changed_files`, `clear_cache`)
- `remove-s4-class.R` — S4 class cleanup on unload (topological sort of class hierarchy)
- `run-loadhooks.R` — `.onLoad` / `.onAttach` hook execution
