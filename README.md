# loadfast

> [!NOTE]
> The majority of this codebase was written with AI assistance. It is covered by
> an extensive behavioral test suite (`test_loadfast.R`, plus a `testthat` suite
> that runs under `R CMD check`) and a multi-platform CI matrix; we rely on it
> daily.

`loadfast` is an R package for interactive development on large R packages. It is intended as a drop-in replacement for `devtools::load_all()` when reload time is a bottleneck.

For a given package path, `loadfast` performs a full load on the first call, then uses MD5-based change detection to re-source only changed `R/` files on subsequent calls.

`loadfast` is intended for the edit-reload-test loop, not as a general replacement for `devtools::load_all()`. The main tradeoff is described in [Important limitation: incremental reload does not clean up stale symbols](#important-limitation-incremental-reload-does-not-clean-up-stale-symbols).

At runtime, `loadfast` does not depend on `pkgload` or `devtools`. Its main runtime dependency is `rlang`.

## Installation

Install from GitHub with either `pak` or `remotes`:

```r
pak::pkg_install("finccam/loadfast")
# or
remotes::install_github("finccam/loadfast")
```

## Usage

Call `load_fast()` from a package root or from any path inside a package:

```r
loadfast::load_fast()
# or
loadfast::load_fast("path/to/your/package")
```

`load_fast()` reads the package name from `DESCRIPTION`, attaches `Depends` packages, builds a namespace, processes `NAMESPACE` imports, sources `R/` files (respecting the `Collate` field), attaches the package to the search path, and optionally sources testthat helpers.

It supports packages that rely on standard R namespace behavior, including imports, S3 methods (registered via `S3method()`), S4 classes, and R6 classes. Exports declared with `export()`, `exportPattern()`, `exportClasses()`, and `exportMethods()` are all honored, so a `load_fast()`-loaded package can be depended on by another package in the same session. `.onLoad`, `.onAttach`, and `.onUnload` hooks run at the same points as they do for `library()` / `load_all()`.

### Options

`load_fast()` supports the following arguments:

- `helpers = TRUE` to source `helper*.R` files from `tests/testthat/` when testthat is available
- `attach_testthat = NULL` to auto-detect whether `testthat` should be attached
- `full = TRUE` to force a complete teardown and rebuild
- `verbose = TRUE` to emit per-phase timing logs

If runtime code needs a specific file to be re-sourced on the next load, call `load_fast_register_reload()` to register that file for reload. This is useful for runtime patching and temporary method overrides.

If `renv.lock` changes between incremental loads for the same package path, `load_fast()` warns. Dependency changes may require restarting R or reinstalling packages.

Reloading the `loadfast` package resets the in-memory loader state, so the next `load_fast()` call for a package path performs a full load.

## Important limitation: incremental reload does not clean up stale symbols

For performance, the incremental path does **not** track which symbols came from which file and does **not** remove stale objects when files are deleted or functions are removed.

This is a conscious tradeoff, not a claim that cleanup is impossible in principle. We have not found a performant enough implementation yet for the large-project use case `loadfast` targets. Approaches based on per-file symbol diffing and repeated enumeration of large namespaces were too slow.

After an incremental reload:

- deleted files can leave old objects behind
- removed variables or functions can remain available in the loaded package until you force a full rebuild

Use `full = TRUE` after deleting files, removing functions, or whenever you need a clean namespace state.

## Working across multiple packages

`load_fast()` can load several interdependent packages from different paths in
the same session: load the dependency first, then the packages that import from
it. Because each namespace is built with the same metadata a real installed
package has (including the `lazydata` field, S3 method tables, and full export
processing), cross-package access works — whether through `importFrom()`,
`import()`, `pkg::name`, S3 dispatch, or `importClassesFrom()` /
`importMethodsFrom()`.

As with `devtools::load_all()`, a package imports its dependencies' symbols as a
snapshot taken at its own load time. `load_fast()` tracks these relationships:

- When you reload a package, every loaded package that imports from it
  (directly or transitively) is **flagged**. Their next `load_fast()` call is
  automatically upgraded to a full reload — a plain `load_fast()` on an importer
  never silently reports "No changes" while it is running against a stale
  dependency snapshot.
- A full reload also reloads flagged dependencies first, in dependency order.
  In a chain `C -> B -> A`, editing and reloading `A` followed by a single
  `load_fast()` of `C` rebuilds `B` and `C` against the fresh namespaces.

So the workflow is simply: reload the package you edited, then reload whatever
package you are working in — everything in between converges automatically.

Reloading a dependency that other loaded packages import cannot use
`unloadNamespace()` (R refuses to unload an imported namespace); `load_fast()`
then runs the old namespace's `.onUnload` hook and force-replaces it in the
namespace registry. This is tested, including S4 class redefinition while the
class is imported elsewhere.

> Earlier versions failed here with `Error: object 'lazydata' not found` when a
> loaded package was accessed with `::`. That is fixed.

## Editor setup

### RStudio

After installation, the addin is available from the Addins menu as `LOADFAST > Load Fast`.

To bind it to a keyboard shortcut:

1. Open `Tools > Modify Keyboard Shortcuts`
2. Filter for `Load fast`
3. Assign the shortcut you want

### VS Code

You can bind `loadfast::load_fast()` directly in `keybindings.json`:

```json
{
  "key": "ctrl+shift+l",
  "command": "workbench.action.terminal.sendSequence",
  "args": {
    "text": "loadfast::load_fast()\n"
  },
  "when": "editorTextFocus && editorLangId == 'r' || terminalFocus"
}
```

### Zed

You can bind `loadfast::load_fast()` in the Zed keymap:

```json
"ctrl-shift-l": [
  "workspace::SendKeystrokes",
  # note: you also need to add a command to focus the terminal first
  "l o a d f a s t : : l o a d _ f a s t ( )" 
]
```

## Testing

Testing happens at two levels:

1. **Behavioral harness** (`test_loadfast.R`): ~300 checks across seven stages
   covering full loads, incremental reloads, cross-file and cross-package
   dependencies, S3/S4/R6 fidelity, multi-package dependency invalidation, and
   production hardening (failed-load recovery, rename-in-place, `Depends`
   attachment, `Collate` ordering, re-entrance).
2. **`testthat` suite** (`tests/testthat/`): self-contained smoke and error-path
   tests that run against the *installed* package during `R CMD check`.

Run the full harness with:

```sh
Rscript test_loadfast.R
```

Run only matching checks by setting `LOADFAST_TEST_FILTER`. The value is treated as a regular expression matched against each check description.

Example:

```sh
LOADFAST_TEST_FILTER="inter-pkg|dep-order" Rscript test_loadfast.R
```

CI runs the harness on Linux, Windows, and macOS, plus `R CMD check --as-cran`
on all three platforms (and one older R release). The check is clean apart from
two expected NOTEs: the `attach()` call (inherent to what a loader does — the
same NOTE `pkgload` carries) and, on some runners, an environment-specific
timestamp note.
