# loadfast

`loadfast` is an R package for interactive development on large R packages. It is intended as a drop-in replacement for `devtools::load_all()` when reload time is a bottleneck.

For a given package path, `loadfast` performs a full load on the first call, then uses MD5-based change detection to re-source only changed `R/` files on subsequent calls.

`loadfast` is intended for the edit-reload-test loop, not as a general replacement `devtools::load_all()` . The main tradeoff is described in [Important limitation: incremental reload does not clean up stale symbols](#important-limitation-incremental-reload-does-not-clean-up-stale-symbols).

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

`load_fast()` reads the package name from `DESCRIPTION`, builds a namespace, processes `NAMESPACE` imports, sources `R/` files, attaches the package to the search path, and optionally sources testthat helpers.

It supports packages that rely on standard R namespace behavior, including imports, S4 classes, and R6 classes.

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

This means that after an incremental reload:

- deleted files can leave old objects behind
- removed variables or functions can remain available in the loaded package until you force a full rebuild

Pass `full = TRUE` to force a complete teardown+rebuild. You should do this after deleting files, removing functions, or whenever you need a clean namespace state.

## Editor setup

### RStudio

After installation, the addin is available from the addin dropdown as `LOADFAST > Load Fast`.

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
  "l o a d f a s t : : l o a d _ f a s t ( )" # you need a shortcut to focus terminal first
]
```

## Testing

This repository uses a custom test harness.

Run the full test suite with:

```sh
Rscript test_loadfast.R
```
