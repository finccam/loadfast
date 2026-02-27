# AGENTS.md — Non-obvious context for working in this repo

# Hygiene

This `AGENT.md` file is read by every agent session. !!!Keep them high-signal!!! (delete obvious information)

# Coding guidelines

* Do not write organizational or comments that summarize the code. Comments should only be written in order to explain "why" the code is written in some way in the case there is a reason that is tricky / non-obvious.
* Prefer implementing functionality in existing files unless it is a new logical component. Avoid creating many small files.

## Project layout

- **`loadfast.R`** (top-level) is the standalone replacement for `devtools::load_all()`. It is independent of the pkgload package and is designed to be copied into the user's own project.
- **`test_loadfast.R`** (top-level) is the test harness. Run with `Rscript test_loadfast.R` from the `loadfast/` directory. It exercises `load_fast()` in two stages (project1 → project2 reload) and also runs `testthat::test_dir()` against each project's own testthat suite.
- **`project1/`** and **`project2/`** are frozen package snapshots used by the tests. Each contains `DESCRIPTION`, `NAMESPACE`, `R/` (source files), and `tests/testthat/` (testthat tests + helpers). Both have the **same `Package: devpackage`** name — this is intentional (see testing section below).
  - `R/base.R` — plain functions (`add`, `scale_vector`, `summarize_values`)
  - `R/s4_classes.R` — S4 classes (`Animal`, `Pet`), generics, methods
  - `R/r6_classes.R` — R6 classes (`Logger`, `Counter`)
  - `tests/testthat/helper-utils.R` — testthat helper factories (`make_test_animal`, `make_test_logger`)
  - `tests/testthat/test-base.R` — testthat tests exercising all of the above
- **`renv/`** and **`renv.lock`** manage the project-local library. Key packages: `testthat`, `R6`, `rlang`.
- **`pkgload/`** contains the original pkgload R package source code (moved here for reference). It is NOT used at runtime.

## loadfast.R design decisions

- The package name is **read from the `Package:` field in DESCRIPTION**. No hard-coding required — just set the field in your DESCRIPTION file.
- `load_fast(path)` takes a **path to a package root** (a directory containing `DESCRIPTION`, `NAMESPACE`, and `R/`). It does not assume `.`.
- Requires **`rlang`** as a runtime dependency (for `rlang::ns_registry_env()`). The user already has it because they use devtools.
- DESCRIPTION is parsed only for the `Package:` field. Imports are read from the **NAMESPACE** file.
- `load_fast()` accepts `helpers` and `attach_testthat` parameters (mirroring pkgload's `load_all`). When `helpers = TRUE` (the default) and testthat is available, it calls `testthat::source_test_helpers()` to source `helper*.R` files from `tests/testthat/` into the attached package environment — the same behavior as pkgload.
- `attach_testthat` defaults to auto-detect: if `tests/testthat/` (or `inst/tests/`) exists and testthat is installed, testthat is attached to the search path via `library("testthat")`.

## Testing gotchas

- Both project snapshots must declare the **same `Package:` name**. If they differ, `load_fast()` would load two independent packages and the detach/unregister/rebuild path would never be exercised.
- Both NAMESPACE files are currently **identical**. The test does not yet cover NAMESPACE changes across reloads.
- The `check()` helper wraps test expressions in `quote()` and evaluates with `eval(..., envir = parent.frame())`. Without `quote()`, errors from the assertion itself would escape `tryCatch`.
- `test_loadfast.R` also runs `testthat::test_dir()` against each project's `tests/testthat/` directory after `load_fast()`, passing the attached package environment so that testthat can find the package's exported objects and helpers.
- project2 intentionally changes behavior across all three class systems (plain functions, S4, R6) so the reload path is exercised for each. Examples: `Logger` gains a `level` field and `format_entries()` method; `Counter` gains `decrement()`; `Animal` gains an `age` slot; `summarize_values()` adds a `range` element.

## R namespace machinery gotchas

### A plain `new.env()` is not enough for S4
S4's `setClass`/`setMethod` rely on `topenv()` and `isNamespace()` internally. A plain `new.env(parent = globalenv())` will NOT be recognized as a namespace. You must:
1. Create the proper env chain: `<namespace:pkg>` → `<imports:pkg>` → `.BaseNamespaceEnv`
2. Set up `.__NAMESPACE__.` metadata environment with `spec`, `exports`, `imports`, etc.
3. **Register the env in R's internal namespace registry** so `isNamespace()` returns `TRUE`.

R's `registerNamespace` is an `.Internal` and cannot be called from user code. The workaround is `rlang::ns_registry_env()` which returns the registry as an R environment — you can assign directly into it: `reg[[pkg_name]] <- ns_env`.

### `makeNamespace` is not exported
`makeNamespace` is a **local function defined inside `base::loadNamespace`**. It is not accessible directly. pkgload extracts it at load time via AST manipulation (`extract_lang` + `modify_lang`). In `loadfast.R` we instead replicate its logic inline.

### S4 "no definition for class" is a `message()`, not a `warning()`
On R 4.2.2 (and possibly other versions), `methods:::matchSignature` emits the "no definition for class" notice via `message()`, **not** `warning()`. This means `suppressWarnings()` does NOT suppress it — you need `suppressMessages()` or a `withCallingHandlers` that catches **both** `warning` and `message` conditions. This was discovered empirically; the decompiled source appears to show `warning()` but the runtime behavior is `message()`.

These notices are **harmless**. They fire when `setMethod()` is sourced before the corresponding `setClass()` due to alphabetical file ordering. The methods still register correctly. Installed packages never hit this because they load from pre-compiled lazy-load databases (no re-execution of `setClass`/`setMethod`).

### S4 class redefinition on reload requires full unregister
When reloading a package that redefines an S4 class (e.g. adding a slot), the old class definition must be fully evicted first. This works in `loadfast.R` because the reload path calls `unloadNamespace()` (or force-removes from the registry), which clears the methods package's internal class cache. Without this, `setClass()` would see the old definition and the new slot would silently fail to appear.

### `parseNamespaceFile` path convention
`parseNamespaceFile(package, package.lib)` constructs the path as `<package.lib>/<package>/NAMESPACE`. So to parse `./NAMESPACE` you must call:
```r
parseNamespaceFile(basename(abs_path), dirname(abs_path))
```
NOT `parseNamespaceFile(pkg_name, ".")` — that would look for `./<pkg_name>/NAMESPACE`.

### `namespaceImport` / `namespaceImportFrom` target the **imports env**
These base R functions place objects into the **parent** of the namespace env (the `imports:<pkg>` env), not into the namespace itself. This is correct R semantics — the namespace inherits from the imports env.

## System-specific notes

- **OS**: Windows
- **R version**: 4.2.2
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
