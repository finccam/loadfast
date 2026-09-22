# Technical debt

This document tracks known implementation debt and conscious tradeoffs in the `loadfast` package implementation under `R/`. It is intentionally short and action-oriented. The goal is to preserve context for future edits without restating the whole implementation.

## Current status

- The package implementation under `R/` passes the repo harness (`test_loadfast.R`,
  ~300 checks) and the `testthat` suite that runs under `R CMD check`.
- `R CMD check --as-cran` is clean apart from two expected NOTEs: the `attach()`
  call (inherent to a loader that manages the search path) and an
  environment-specific timestamp note on some machines.
- Namespace fidelity matches `loadNamespace()` for the areas that affect real
  packages and multi-package sessions: S3 method registration (`S3method()`),
  full export processing (`export()`, `exportPattern()`, `exportClasses()`,
  `exportMethods()`), the `lazydata` / `nativeRoutines` namespace-info fields,
  the namespace version from `DESCRIPTION`, `Depends` attachment, and the
  `.onLoad` / `.onAttach` / `.onUnload` hooks. See the namespace-machinery notes
  in `AGENTS.md`.

## Resolved (previously tracked as debt)

### Incremental cache validity (was medium priority)
The incremental path verifies that the cached namespace env is identical to the
currently registered namespace (`asNamespace(pkg)`) and that the package env is
on the search path. Stale env references after manual unloads fall back to a
full load.

### Cache keyed only by normalized path (was medium priority)
Cache entries store `pkg_name`. When the `Package:` field changes in place for
the same directory, the loader detaches and unloads the old identity, drops the
stale cache entry, and does a full load under the new name (tested in stage 7b).

### Testthat detection duplication (was low priority)
Extracted into `.loadfast.uses_testthat()` / `.loadfast.attach_testthat()`.

## Remaining low-priority debt

### Package env sync logic is duplicated conceptually
The full-load and incremental-load paths both bulk-copy namespace and imports
into the attached package env. The duplication is reasonable, but it is a
maintenance seam. Optionally extract a small helper if the file grows further.

## Conscious tradeoffs, not bugs

These should not be "fixed" casually unless the project goals change.

### 1. Incremental reload does not clean up stale symbols
The incremental path does not track which symbols came from which file and does not remove stale objects when files are deleted or functions are removed.

This is intentional. It avoids the symbol-tracking and repeated enumeration costs that made previous approaches too slow on large projects.

**Current rule**
- Use `full = TRUE` when files are deleted or exported objects are removed

### 2. `renv.lock` warning persists until a full reload
When `renv.lock` changes, incremental reload continues to warn on later calls until a full reload resets the baseline.

This is intentional and tested. It favors making dependency drift obvious over silently accepting a new lockfile baseline.

### 3. Incremental reload does not re-read `NAMESPACE`
The incremental path only re-sources changed `R/` files. It does not re-parse
`NAMESPACE`, so imports and the *set* of exports/`S3method()` declarations are
fixed at the initial full load. Editing a function body is picked up
incrementally (and S3 method tables are rebuilt so re-sourced methods take
effect), but **adding** a new `export()`, `S3method()`, or `importFrom()` needs
`full = TRUE`.

This mirrors the existing treatment of imports and matches the "use `full =
TRUE` after structural changes" guidance. Re-parsing `NAMESPACE` every call was
not worth the cost for the edit-reload loop.

**Current rule**
- Use `full = TRUE` after editing `NAMESPACE` (new exports, S3 methods, imports)

### 4. `Collate` support is intentionally narrow
The loader respects the `Collate` field from `DESCRIPTION` when ordering
`R/*.R` files, on both full loads and incremental re-sourcing, and this
behavior is covered by the test suite (stages 3d and 7e).

This is still intentionally lightweight rather than a full reproduction of every package-loading edge case. Future changes should preserve the current `Collate` behavior without overcomplicating the package implementation.

**Current rule**
- Treat `Collate` ordering for `R/*.R` as supported behavior
- Be cautious about expanding this area unless a concrete incompatibility appears

### 5. Dependency invalidation forces a full reload of importers
When a package is re-sourced (fully or incrementally), every cached package
that imports from it — directly or transitively — is flagged, and its next
`load_fast()` call is upgraded to a full reload (which in turn reloads flagged
dependencies first, in dependency order). This matches `load_all()`'s cost
model: importers always re-process imports against fresh namespaces.

A cheaper in-place refresh of importer imports envs was considered and
rejected for now: it would have to reproduce `namespaceImportFrom()` /
`importMethodsFrom()` merge semantics against live namespaces, which is exactly
the class of subtle S4/S3 state this package tries not to reimplement.

**Current rule**
- Correctness first: flagged importers do a full reload; the within-package
  incremental path remains the performance win

### 6. S4 metadata helpers are inlined, not imported from methods:::
`.loadfast.has_s4_metadata()`, `.loadfast.s4_method_tables()`, and
`.loadfast.s4_generic_names()` replicate tiny `methods:::` internals
(`.hasS4MetaData`, `.getGenerics`, `.TableMetaPrefix`) using the stable
`.__C__` / `.__T__` / `.__A__` metadata naming convention. This keeps
`R CMD check --as-cran` free of the `:::` warning. If a future R version
changes these conventions (unlikely; they are decades old), stages 5d/6e of the
harness will catch it.

## Notes for future reviewers

- Most of the implementation complexity is justified by R namespace machinery, especially S4 behavior and imports metadata shape.
- The current code is more "pragmatic systems R" than elegant, which is appropriate here.
- Avoid refactoring for style alone unless it clearly improves correctness, installability, or package ergonomics.
